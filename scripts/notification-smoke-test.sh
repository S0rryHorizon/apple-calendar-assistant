#!/bin/zsh
set -euo pipefail

bridge="${CALENDAR_BRIDGE_PATH:-${HOME}/Applications/CalendarBridge.app/Contents/MacOS/CalendarBridge}"
script_path="${0:A}"
if [[ ! -x "${bridge}" ]]; then
  echo "CalendarBridge 不可执行：${bridge}" >&2
  exit 1
fi

# Every invocation is a separate JSON request. A zero exit code alone is not a receipt.
call_bridge() {
  local stage="$1" request="$2" response
  if ! response="$(printf '%s\n' "${request}" | "${bridge}")"; then
    echo "${stage} 调用失败；批次 ID：${batch_id:-尚未生成}。请人工核查，不要重试。" >&2
    return 1
  fi
  if ! python3 - "${stage}" "${batch_id:-}" "${response}" <<'PY'
import json
import sys

stage, batch_id, raw = sys.argv[1:]
try:
    receipt = json.loads(raw)
except (ValueError, TypeError):
    receipt = None

expected = {"setup": "ok", "preview": "preview", "commit": "committed", "cleanup": "rolled_back"}[stage]
valid = isinstance(receipt, dict) and receipt.get("ok") is True and receipt.get("status") == expected
if valid and stage != "setup":
    valid = receipt.get("batchId") == batch_id
if valid and stage == "preview":
    valid = receipt.get("conflicts") == [] and receipt.get("duplicates") == []
if not valid:
    print(f"{stage} 回执未确认成功；批次 ID：{batch_id or '尚未生成'}。请人工核查，不要重试。", file=sys.stderr)
    sys.exit(1)
PY
  then
    return 1
  fi
}

if [[ "${1:-}" == "--cleanup" ]]; then
  batch_id="${2:-}"
  if [[ -z "${batch_id}" || $# -ne 2 ]]; then
    echo "Usage: $0 --cleanup BATCH_ID" >&2
    exit 2
  fi
  request="$(python3 - "${batch_id}" <<'PY'
import json
import sys
print(json.dumps({"action": "batch.rollback", "batchId": sys.argv[1], "confirmed": True}))
PY
)"
  call_bridge cleanup "${request}"
  echo "批次已回滚：${batch_id}"
  exit 0
fi

if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--cleanup BATCH_ID]" >&2
  exit 2
fi

call_bridge setup '{"action":"setup"}'
batch_id="notification-smoke-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
preview_request="$(python3 - "${batch_id}" <<'PY'
import datetime as dt
import json
import sys
from zoneinfo import ZoneInfo

now = dt.datetime.now(ZoneInfo("Asia/Singapore")).replace(microsecond=0)
payload = {
    "action": "event.create",
    "dryRun": True,
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
call_bridge preview "${preview_request}"

commit_request="$(python3 - "${preview_request}" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
del payload["dryRun"]
payload["confirmed"] = True
print(json.dumps(payload, ensure_ascii=False))
PY
)"
call_bridge commit "${commit_request}"

echo "请等待约一分钟，在 Mac 或 iPhone 上确认系统通知。"
echo "测试后清理："
printf '  CALENDAR_BRIDGE_PATH=%s %s --cleanup %s\n' \
  "${(q)bridge}" "${(q)script_path}" "${(q)batch_id}"
