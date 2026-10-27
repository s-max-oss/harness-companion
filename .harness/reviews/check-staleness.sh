#!/bin/bash
# checks three-axis staleness on the newest run
set -u
cd "D:/HuaweiMoveData/Users/20805/Desktop/homework/GitHub learning/harness-companion skill/harness-companion"
source core/lib/staleness.sh
NEWEST="$(ls -t .harness/logs/runs/*.ndjson | head -1)"
echo "newest: $NEWEST"
RUN_ID="${NEWEST##*/}"
RUN_ID="${RUN_ID%.ndjson}"
echo "run_id: $RUN_ID"
for axis in fingerprint config vcs; do
  fn="ev_is_stale_by_${axis}"
  if "$fn" "$RUN_ID" .; then
    echo "  axis $axis: STALE"
  else
    echo "  axis $axis: FRESH"
  fi
done
