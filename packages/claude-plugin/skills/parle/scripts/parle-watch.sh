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
# the adapters publish. The DEAD verdict is era-gated: only after this watch
# has itself seen the session live in a snapshot does present-then-absent
# (for two consecutive checks) exit 3. A session id that was NEVER present
# is inconclusive -- host predating snapshot publishing, another cwd, or a
# missing file for a live server (observed in the field, adapters#22) -- so
# the watch notes it once on stderr and keeps holding. No snapshots at all
# is likewise indeterminate (direct-HTTP sessions publish none). Set
# PARLE_WATCH_SESSION_LIVENESS=0 to disable the check entirely.
#
# Needs: PARLE_API_BASE, PARLE_ROOM_ID, PARLE_ROOM_AGENT_TOKEN
# Exit:  0 = relevant activity past since_seq, 2 = terminal or repeated
#        failures, 3 = my_agent_session_id was live on this host and is now
#        gone (reconnect with parle_connect and arm a fresh watch; do not
#        re-arm with the old id or watermark; if parle_connect says the
#        session is still alive, re-arm with PARLE_WATCH_SESSION_LIVENESS=0)
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

# LIVE = a runtime snapshot for $me is live; DEAD = live snapshots exist but
# none matches $me; UNKNOWN = no parseable snapshots (indeterminate, keep
# watching). Mirrors isLiveRuntimeSnapshot in @parlehq/agent-client
# (schemaVersion 1, state ready, unexpired with 30s skew, writer pid alive;
# uncertain pid checks count as alive, matching the client's prune posture).
session_liveness() {
  [ -n "$me" ] || { echo LIVE; return; }
  [ "${PARLE_WATCH_SESSION_LIVENESS:-1}" = "0" ] && { echo LIVE; return; }
  [ -d ./.parle/runtime ] || { echo UNKNOWN; return; }
  python3 - "$me" <<'PY' 2>/dev/null || echo UNKNOWN
import calendar, glob, json, os, re, sys, time

me = sys.argv[1]
now = time.time()
parsed_live = 0
# ISO-8601 UTC as written by JS toISOString(); parsed portably because the
# host python3 can be as old as 3.6 (no datetime.fromisoformat).
ISO_UTC = re.compile(r"^(\d{4}-\d{2}-\d{2})[Tt](\d{2}:\d{2}:\d{2})(?:\.\d+)?(?:[Zz]|\+00:00)$")
for path in glob.glob("./.parle/runtime/*.json"):
    try:
        with open(path) as f:
            snap = json.load(f)
    except Exception:
        continue
    if not isinstance(snap, dict) or snap.get("schemaVersion") != 1 or snap.get("state") != "ready":
        continue
    match = ISO_UTC.match(str(snap.get("expiresAt", "")))
    if not match:
        continue
    expires = calendar.timegm(time.strptime(match.group(1) + " " + match.group(2), "%Y-%m-%d %H:%M:%S"))
    if expires <= now + 30:
        continue
    pid = snap.get("pid")
    if not isinstance(pid, int) or pid <= 0:
        continue
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        continue
    except Exception:
        pass
    parsed_live += 1
    if snap.get("agentSessionId") == me:
        print("LIVE")
        sys.exit(0)
print("DEAD" if parsed_live else "UNKNOWN")
PY
}

fails=0
dead_liveness=0
# Era gate: only trust a DEAD verdict after this watch has itself observed the
# session live in the snapshots (present-then-absent). A session id that was
# NEVER present is inconclusive -- the host may predate snapshot publishing,
# run in another cwd, or its live server's file may be missing (observed in
# the field, adapters#22) -- so the watch holds and says why once.
seen_live=0
noted_never_present=0
while :; do
  liveness_state=$(session_liveness)
  if [ "$liveness_state" = "LIVE" ] && [ -n "$me" ]; then seen_live=1; fi
  if [ "$liveness_state" = "DEAD" ]; then
    if [ "$seen_live" != "1" ]; then
      if [ "$noted_never_present" = "0" ]; then
        noted_never_present=1
        echo "Parle note: agent session $me has never appeared in ./.parle/runtime snapshots, so its absence is inconclusive and this watch keeps holding. If parle_connect reports a different live session id, re-arm with that id and cursor; if it reports this session alive, the snapshot is missing and PARLE_WATCH_SESSION_LIVENESS=0 silences this check until the host reloads." >&2
      fi
      dead_liveness=0
    else
      dead_liveness=$((dead_liveness + 1))
      if [ "$dead_liveness" -ge 2 ]; then
        echo "Parle stopped: agent session $me was live in this host's runtime snapshots and is now gone (host process reloaded, session ended, or expired). Reconnect with parle_connect, then arm a fresh watch with the returned cursor and agentSessionId. Do not re-arm with this session id or watermark. If parle_connect reports this same session alive, treat this as a false verdict and re-arm with PARLE_WATCH_SESSION_LIVENESS=0." >&2
        exit 3
      fi
      sleep 1
      continue
    fi
  fi
  if [ "$liveness_state" != "DEAD" ]; then dead_liveness=0; fi
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
