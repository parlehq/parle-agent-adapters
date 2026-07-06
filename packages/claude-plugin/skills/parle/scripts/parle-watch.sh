#!/bin/sh
# parle-watch.sh -- exit 0 when the Parle room watermark passes SINCE_SEQ.
#
# Run in the background from a Claude Code session; the exit re-wakes the
# session, which then drains parle_inbox and restarts the watch with the
# new watermark. One held long-poll connection, no tight loops.
#
# Usage: parle-watch.sh <since_seq>
# Needs: PARLE_API_BASE, PARLE_ROOM_ID, PARLE_ROOM_AGENT_TOKEN, PARLE_VERSION
# Exit:  0 = room activity past since_seq, 2 = giving up after repeated failures
set -u
since="${1:?usage: parle-watch.sh <since_seq>}"
fails=0
while :; do
  wm=$(curl -sf --max-time 40 \
    "$PARLE_API_BASE/v/rooms/$PARLE_ROOM_ID/inbound?since_seq=$since&wait=25" \
    -H "Authorization: Bearer $PARLE_ROOM_AGENT_TOKEN" \
    -H "Parle-Version: $PARLE_VERSION" |
    sed -n 's/.*"watermark":\([0-9][0-9]*\).*/\1/p')
  if [ -n "${wm:-}" ]; then
    fails=0
    if [ "$wm" -gt "$since" ]; then
      echo "parle-watch: watermark $since -> $wm"
      exit 0
    fi
  else
    fails=$((fails + 1))
    if [ "$fails" -ge 10 ]; then
      echo "parle-watch: $fails consecutive failures, giving up" >&2
      exit 2
    fi
    sleep $((fails * 5))
  fi
done
