#!/usr/bin/env bash
# 部署或切換期間持續打一個網址，統計失敗數。部署前啟動，部署結束後 touch 停止旗標：
#
#   ./probe.sh https://api.example.com/api/health /tmp/stop-probe &
#   ./release.sh; sleep 20; touch /tmp/stop-probe; wait
#
# 不停機部署的標準：failed 必須是 0。
set -uo pipefail
url=${1:?usage: probe.sh <url> <stop-flag-file>}
stop=${2:?usage: probe.sh <url> <stop-flag-file>}
rm -f "$stop"
ok=0
bad=0
while [ ! -f "$stop" ]; do
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url")
  if [ "$code" = 200 ]; then
    ok=$((ok + 1))
  else
    bad=$((bad + 1))
    echo "$(date -u +%T) $code" >&2
  fi
  sleep 0.5
done
echo "$url: $ok ok, $bad failed"
[ "$bad" -eq 0 ]
