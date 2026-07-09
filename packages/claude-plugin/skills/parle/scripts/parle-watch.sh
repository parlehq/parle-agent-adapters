#!/bin/sh
# parle-watch.sh -- exit 0 when relevant room activity lands past SINCE_SEQ.
#
# Run in the background from a Claude Code session; the exit re-wakes the
# session, which then drains parle_inbox and restarts the watch. One held
# long-poll connection, no tight loops.
#
# Usage: parle-watch.sh <since_seq> [my_agent_session_id]
#
# With my_agent_session_id set, rows you authored and directs addressed to
# other sessions are skipped instead of waking you, so busy multi-session
# rooms stay quiet and the own-send restart caveat disappears. Your id is
# the addressing.target_agent_session_id on any direct you received, or
# author.agent_session_id on rows you authored in parle_read. Without it,
# any new room row wakes you (v1 behavior).
#
# Session liveness: the projection poll authenticates with the room agent
# token alone, so the server cannot tell this script that the session it
# filters on has died (host reload, session end). When my_agent_session_id
# is set, each cycle also checks the local .parle/runtime/*.json snapshots
# the adapters publish. Own-snapshot evidence is classified before absence
# counts for anything: a snapshot carrying this id that is expired (or within
# the 30s guard band) or whose writer pid is dead is AFFIRMATIVE evidence the
# session is gone and exits 3 regardless of history; one that is present but
# not ready (bootstrap retry or failure in progress) holds as inconclusive.
# Plain absence is era-gated: only after this watch has itself seen the
# session live in a snapshot does present-then-absent (for two consecutive
# checks) exit 3. A session id that was NEVER present is inconclusive -- host
# predating snapshot publishing, another cwd, or a missing file for a live
# server (observed in the field, adapters#22) -- so the watch notes it once
# on stderr and keeps holding. No snapshots at all is likewise indeterminate
# (direct-HTTP sessions publish none). Every exit 3 is preceded by a
# redaction-safe per-file forensics dump on stderr so a disputed verdict is
# arguable from evidence. Set PARLE_WATCH_SESSION_LIVENESS=0 to disable the
# check entirely.
#
# Needs: PARLE_API_BASE, PARLE_ROOM_ID, PARLE_ROOM_AGENT_TOKEN
# Exit:  0 = relevant activity past since_seq, 2 = terminal or repeated
#        failures, 3 = my_agent_session_id is gone from this host (reconnect
#        with parle_connect and arm a fresh watch; do not re-arm with the old
#        id or watermark). An exit 3 near the session's scheduled expiresAt
#        is expected pre-expiry rollover, not a heuristic failure. If
#        parle_connect says the same session is alive, check the remaining
#        TTL: seconds to spare confirms the rollover; plenty of TTL means a
#        false verdict -- re-arm with PARLE_WATCH_SESSION_LIVENESS=0
#
# Config self-loads from the same sources and precedence as the adapters
# client: process env first, then ./.env, then ./.parle/credentials (relative
# to the cwd). PARLE_VERSION is adapter-owned: only a process-env value
# overrides the script default. Run it from the project directory and no env
# injection or wrapper is needed.
set -u
since="${1:?usage: parle-watch.sh <since_seq> [my_agent_session_id]}"
me="${2:-}"

load_missing() {
  key="$1"
  eval "current=\${$key:-}"
  [ -n "$current" ] && return 0
  for f in ./.env ./.parle/credentials; do
    [ -f "$f" ] || continue
    val=$(sed -n "s/^[[:space:]]*${key}=//p" "$f" | head -1 | tr -d '\r')
    # strip one layer of matching quotes
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    if [ -n "$val" ]; then
      export "$key=$val"
      return 0
    fi
  done
}
load_missing PARLE_API_BASE
load_missing PARLE_ROOM_ID
load_missing PARLE_ROOM_AGENT_TOKEN
if [ -z "${PARLE_VERSION:-}" ]; then
  for f in ./.env ./.parle/credentials; do
    if [ -f "$f" ] && grep -q '^[[:space:]]*PARLE_VERSION=' "$f"; then
      echo "Parle warning: ignoring persisted PARLE_VERSION in $f; remove it. Set PARLE_VERSION in process env only for staging or rollback." >&2
    fi
  done
fi
: "${PARLE_API_BASE:=https://api.parle.sh}"
: "${PARLE_VERSION:=2026-07-07}"
if [ -z "${PARLE_ROOM_ID:-}" ] || [ -z "${PARLE_ROOM_AGENT_TOKEN:-}" ]; then
  echo "Parle stopped: required host configuration is missing. PARLE_ROOM_ID / PARLE_ROOM_AGENT_TOKEN not found in env, ./.env, or ./.parle/credentials (run from the project directory)" >&2
  exit 2
fi

# LIVE = a runtime snapshot for $me is live. MINE_EXPIRED = $me's snapshot is
# past (or within the 30s guard band of) its expiresAt -- affirmative
# scheduled expiry. MINE_PIDDEAD = $me's snapshot names a dead writer pid --
# the host process exited. MINE_UNREADY = $me's snapshot exists but is not
# ready (bootstrap retry or failure in progress) -- inconclusive, hold.
# DEAD = live sibling snapshots exist and none carries $me. UNKNOWN = no
# parseable snapshots (indeterminate, keep watching). Mirrors
# isLiveRuntimeSnapshot in @parlehq/agent-client (schemaVersion 1, state
# ready, unexpired with 30s skew, writer pid alive; uncertain pid checks
# count as alive, matching the client's prune posture).
session_liveness() {
  [ -n "$me" ] || { echo LIVE; return; }
  [ "${PARLE_WATCH_SESSION_LIVENESS:-1}" = "0" ] && { echo LIVE; return; }
  [ -d ./.parle/runtime ] || { echo UNKNOWN; return; }
  python3 - "$me" <<'PY' 2>/dev/null || echo UNKNOWN
import calendar, glob, json, os, re, sys, time

me = sys.argv[1]
now = time.time()
sibling_live = 0
mine = []
# ISO-8601 UTC as written by JS toISOString(); parsed portably because the
# host python3 can be as old as 3.6 (no datetime.fromisoformat).
ISO_UTC = re.compile(r"^(\d{4}-\d{2}-\d{2})[Tt](\d{2}:\d{2}:\d{2})(?:\.\d+)?(?:[Zz]|\+00:00)$")

def expiry_epoch(snap):
    match = ISO_UTC.match(str(snap.get("expiresAt", "")))
    if not match:
        return None
    return calendar.timegm(time.strptime(match.group(1) + " " + match.group(2), "%Y-%m-%d %H:%M:%S"))

def pid_alive(snap):
    pid = snap.get("pid")
    if not isinstance(pid, int) or pid <= 0:
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except Exception:
        pass
    return True

for path in glob.glob("./.parle/runtime/*.json"):
    try:
        with open(path) as f:
            snap = json.load(f)
    except Exception:
        continue
    if not isinstance(snap, dict) or snap.get("schemaVersion") != 1:
        continue
    expires = expiry_epoch(snap)
    alive = pid_alive(snap)
    if snap.get("agentSessionId") == me:
        # Own-file evidence beats absence: expiry and a dead writer pid are
        # affirmative "gone"; anything else non-live holds as inconclusive.
        if expires is not None and expires <= now + 30:
            mine.append("MINE_EXPIRED")
        elif alive is False:
            mine.append("MINE_PIDDEAD")
        elif snap.get("state") == "ready" and expires is not None and alive:
            print("LIVE")
            sys.exit(0)
        else:
            mine.append("MINE_UNREADY")
        continue
    if snap.get("state") != "ready":
        continue
    if expires is None or expires <= now + 30:
        continue
    if not alive:
        continue
    sibling_live += 1

for state in ("MINE_UNREADY", "MINE_EXPIRED", "MINE_PIDDEAD"):
    if state in mine:
        print(state)
        sys.exit(0)
print("DEAD" if sibling_live else "UNKNOWN")
PY
}

# Redaction-safe per-file diagnostics on stderr before any exit 3, so a
# disputed verdict is arguable from evidence instead of reconstruction
# (adapters#22: the first field incident spent three hypotheses because the
# exit destroyed its own evidence). Session ids are room-visible operational
# metadata, never credentials.
liveness_forensics() {
  echo "parle-watch forensics: watched=$me verdict=$1" >&2
  python3 - "$me" <<'PY' >&2 2>/dev/null || echo "parle-watch forensics: unavailable (python3 failed)" >&2
import calendar, glob, json, os, re, sys, time

me = sys.argv[1]
now = time.time()
ISO_UTC = re.compile(r"^(\d{4}-\d{2}-\d{2})[Tt](\d{2}:\d{2}:\d{2})(?:\.\d+)?(?:[Zz]|\+00:00)$")
files = sorted(glob.glob("./.parle/runtime/*.json"))
if not files:
    print("  (no files in ./.parle/runtime)")
for path in files:
    try:
        with open(path) as f:
            snap = json.load(f)
    except Exception as e:
        print("  %s unparseable (%s)" % (path, type(e).__name__))
        continue
    if not isinstance(snap, dict):
        print("  %s not an object" % path)
        continue
    pid = snap.get("pid")
    try:
        os.kill(pid, 0)
        alive = "alive"
    except ProcessLookupError:
        alive = "dead"
    except Exception:
        alive = "uncertain"
    raw = str(snap.get("expiresAt", ""))
    match = ISO_UTC.match(raw)
    ttl = None
    if match:
        ttl = int(calendar.timegm(time.strptime(match.group(1) + " " + match.group(2), "%Y-%m-%d %H:%M:%S")) - now)
    print("  %s schema=%s state=%s pid=%s(%s) expiresAt=%s ttl=%s mine=%s" % (
        path, snap.get("schemaVersion"), snap.get("state"), pid, alive,
        raw or "?", "%ds" % ttl if ttl is not None else "?",
        "yes" if snap.get("agentSessionId") == me else "no"))
PY
}

fails=0
dead_liveness=0
gone_liveness=0
unready_liveness=0
# Era gate: only trust an absence-based DEAD verdict after this watch has
# itself observed the session live in the snapshots (present-then-absent).
# A session id that was NEVER present is inconclusive -- the host may predate
# snapshot publishing, run in another cwd, or its live server's file may be
# missing (observed in the field, adapters#22) -- so the watch holds and says
# why once. Affirmative own-file evidence (MINE_EXPIRED, MINE_PIDDEAD) is not
# gated: the snapshot itself proves the session is gone.
seen_live=0
noted_never_present=0
noted_unready=0
while :; do
  liveness_state=$(session_liveness)
  case "$liveness_state" in
    LIVE)
      [ -n "$me" ] && seen_live=1
      dead_liveness=0; gone_liveness=0; unready_liveness=0
      ;;
    MINE_UNREADY)
      # Own snapshot present but not ready: a bootstrap retry or failure in
      # progress, not evidence of death. Hold; say so once if it persists.
      dead_liveness=0; gone_liveness=0
      unready_liveness=$((unready_liveness + 1))
      if [ "$unready_liveness" -ge 2 ] && [ "$noted_unready" = "0" ]; then
        noted_unready=1
        echo "Parle note: agent session $me has a runtime snapshot that is not in the ready state, so this watch keeps holding while the host retries. If it never recovers, check the host session and reconnect with parle_connect." >&2
      fi
      ;;
    MINE_EXPIRED|MINE_PIDDEAD)
      dead_liveness=0; unready_liveness=0
      gone_liveness=$((gone_liveness + 1))
      if [ "$gone_liveness" -ge 2 ]; then
        liveness_forensics "$liveness_state"
        if [ "$liveness_state" = "MINE_EXPIRED" ]; then
          echo "Parle stopped: agent session $me is within the 30-second guard band of (or past) its scheduled expiresAt in this host's runtime snapshot. This is expected pre-expiry rollover, not a heuristic failure. Reconnect with parle_connect, then arm a fresh watch with the returned cursor and agentSessionId; do not re-arm with this session id or watermark." >&2
        else
          echo "Parle stopped: the host process that published agent session $me's runtime snapshot is no longer running. Reconnect with parle_connect, then arm a fresh watch with the returned cursor and agentSessionId; do not re-arm with this session id or watermark." >&2
        fi
        exit 3
      fi
      sleep 1
      continue
      ;;
    DEAD)
      gone_liveness=0; unready_liveness=0
      if [ "$seen_live" != "1" ]; then
        if [ "$noted_never_present" = "0" ]; then
          noted_never_present=1
          echo "Parle note: agent session $me has never appeared in ./.parle/runtime snapshots, so its absence is inconclusive and this watch keeps holding. If parle_connect reports a different live session id, re-arm with that id and cursor; if it reports this session alive, the snapshot is missing and PARLE_WATCH_SESSION_LIVENESS=0 silences this check until the host reloads." >&2
        fi
        dead_liveness=0
      else
        dead_liveness=$((dead_liveness + 1))
        if [ "$dead_liveness" -ge 2 ]; then
          liveness_forensics DEAD
          echo "Parle stopped: agent session $me was live in this host's runtime snapshots and is now gone (host process reloaded, session ended, or expired). Reconnect with parle_connect, then arm a fresh watch with the returned cursor and agentSessionId. Do not re-arm with this session id or watermark. If parle_connect reports this same session alive, check the remaining TTL before suspecting the heuristic: alive with seconds to spare near expiresAt confirms a scheduled rollover, while alive with plenty of TTL means a false verdict -- re-arm with PARLE_WATCH_SESSION_LIVENESS=0." >&2
          exit 3
        fi
        sleep 1
        continue
      fi
      ;;
    *)
      dead_liveness=0; gone_liveness=0; unready_liveness=0
      ;;
  esac
  tmp=$(mktemp "${TMPDIR:-/tmp}/parle-watch.XXXXXX") || exit 2
  status=$(curl -sS --max-time 40 -o "$tmp" -w '%{http_code}' \
    "$PARLE_API_BASE/v/rooms/$PARLE_ROOM_ID/projection?since_seq=$since&wait=25" \
    -H "Authorization: Bearer $PARLE_ROOM_AGENT_TOKEN" \
    -H "Parle-Version: $PARLE_VERSION") || status="000"
  resp=$(cat "$tmp")
  rm -f "$tmp"
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    action=$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    err = (json.load(sys.stdin).get("error") or {})
except Exception:
    err = {}
print(err.get("action") or "network")
print(err.get("code") or "")
print(err.get("retry_after_ms") or "")
')
    err_action=$(printf '%s\n' "$action" | sed -n '1p')
    err_code=$(printf '%s\n' "$action" | sed -n '2p')
    retry_after_ms=$(printf '%s\n' "$action" | sed -n '3p')
    case "$err_action" in
      fix_client)
        echo "Parle stopped: client request is invalid; upgrade or repair the adapter. ${err_code}" >&2
        exit 2
        ;;
      reauthorize)
        echo "Parle stopped: agent token is invalid or revoked; reauthorize the agent. ${err_code}" >&2
        exit 2
        ;;
      rebootstrap)
        echo "Parle stopped: agent session is dead; reconnect with parle_connect and re-arm. ${err_code}" >&2
        exit 2
        ;;
      stop)
        echo "Parle stopped: agent session could not be rebootstrapped; reauthorize or restart. ${err_code}" >&2
        exit 2
        ;;
      backoff|retry_with_backoff|retry)
        fails=$((fails + 1))
        [ -n "$retry_after_ms" ] && sleep_secs=$(( (retry_after_ms + 999) / 1000 )) || sleep_secs=$((fails * 5))
        if [ "$fails" -ge 5 ]; then
          echo "parle-watch: retry budget exhausted after $fails failures" >&2
          exit 2
        fi
        echo "Parle paused: retrying after ${sleep_secs}s (${err_code:-$err_action})." >&2
        sleep "$sleep_secs"
        continue
        ;;
      *)
        fails=$((fails + 1))
        if [ "$fails" -ge 5 ]; then
          echo "parle-watch: $fails consecutive network failures, giving up" >&2
          exit 2
        fi
        sleep $((fails * 5))
        continue
        ;;
    esac
  fi
  fails=0
  out=$(printf '%s' "$resp" | python3 -c '
import json, sys
me = sys.argv[1]
d = json.load(sys.stdin)
rows = d.get("messages") or []
top = max([r.get("seq", 0) for r in rows] + [int(d.get("watermark") or 0)])
def relevant(r):
    author = (r.get("author") or {}).get("agent_session_id") or ""
    addr = r.get("addressing") or {}
    if me and author == me:
        return False
    if me and addr.get("kind") == "direct" and addr.get("target_agent_session_id") != me:
        return False
    return True
print("HIT" if any(relevant(r) for r in rows) else "PASS", top)
' "$me") || out="PASS $since"
  state=${out%% *}
  top=${out##* }
  if [ "$state" = "HIT" ]; then
    echo "parle-watch: relevant activity, seq $since -> $top"
    exit 0
  fi
  if [ "$top" -gt "$since" ] 2>/dev/null; then
    since=$top
  fi
done
