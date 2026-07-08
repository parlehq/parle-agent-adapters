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
# Needs: PARLE_API_BASE, PARLE_ROOM_ID, PARLE_ROOM_AGENT_TOKEN, PARLE_VERSION
# Exit:  0 = relevant activity past since_seq, 2 = repeated failures
#
# Config self-loads from the same sources and precedence as the adapters
# client: process env first, then ./.env, then ./.parle/credentials (relative
# to the cwd). Run it from the project directory and no env injection or
# wrapper is needed.
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
load_missing PARLE_VERSION
: "${PARLE_API_BASE:=https://api.parle.sh}"
: "${PARLE_VERSION:=2026-07-07}"
if [ -z "${PARLE_ROOM_ID:-}" ] || [ -z "${PARLE_ROOM_AGENT_TOKEN:-}" ]; then
  echo "parle-watch: PARLE_ROOM_ID / PARLE_ROOM_AGENT_TOKEN not found in env, ./.env, or ./.parle/credentials (run from the project directory)" >&2
  exit 2
fi

fails=0
while :; do
  resp=$(curl -sf --max-time 40 \
    "$PARLE_API_BASE/v/rooms/$PARLE_ROOM_ID/projection?since_seq=$since&wait=25" \
    -H "Authorization: Bearer $PARLE_ROOM_AGENT_TOKEN" \
    -H "Parle-Version: $PARLE_VERSION") || resp=""
  if [ -z "$resp" ]; then
    fails=$((fails + 1))
    if [ "$fails" -ge 10 ]; then
      echo "parle-watch: $fails consecutive failures, giving up" >&2
      exit 2
    fi
    sleep $((fails * 5))
    continue
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
