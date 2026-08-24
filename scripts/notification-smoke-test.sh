#!/bin/zsh
set -euo pipefail

bridge="${HOME}/Applications/CalendarBridge.app/Contents/MacOS/CalendarBridge"

if [[ "${1:-}" == "--cleanup" ]]; then
  batch_id="${2:-}"
  if [[ -z "${batch_id}" ]]; then
    echo "Usage: $0 --cleanup BATCH_ID" >&2
    exit 2
  fi
  printf '{"action":"batch.rollback","batchId":"%s","confirmed":true}\n' "${batch_id}" | "${bridge}"
  exit 0
fi

echo '{"action":"setup"}' | "${bridge}"
batch_id="notification-smoke-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
request="$(/usr/bin/python3 - "${batch_id}" <<'PY'
import datetime as dt
import json
import sys
from zoneinfo import ZoneInfo

zone = ZoneInfo("Asia/Singapore")
now = dt.datetime.now(zone).replace(microsecond=0)
payload = {
    "action": "event.create",
    "confirmed": True,
    "batchId": sys.argv[1],
    "item": {
        "kind": "event",
        "title": "Calendar Bridge 通知测试（可撤销）",
        "start": (now + dt.timedelta(minutes=5)).isoformat(),
        "end": (now + dt.timedelta(minutes=10)).isoformat(),
        "timezone": "Asia/Singapore",
        "alerts": [{"at": (now + dt.timedelta(minutes=1)).isoformat()}],
        "notes": "通知出现后可用批次回滚删除。",
        "sourceRef": "notification-smoke-test",
    },
}
print(json.dumps(payload, ensure_ascii=False))
PY
)"
printf '%s\n' "${request}" | "${bridge}"
echo
echo "请等待约一分钟，在 Mac 或 iPhone 上确认系统通知。"
echo "测试后清理："
echo "  $0 --cleanup ${batch_id}"
