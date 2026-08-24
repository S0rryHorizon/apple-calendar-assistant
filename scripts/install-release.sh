#!/bin/zsh
set -euo pipefail

package_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="${HOME}/Applications/CalendarBridge.app"
skill_root="${CODEX_HOME:-${HOME}/.codex}/skills"
skill_dir="${skill_root}/apple-calendar-assistant"

[[ -d "${package_dir}/CalendarBridge.app" ]] || {
  echo "找不到 CalendarBridge.app。请从 Release 压缩包的顶层目录运行此脚本。" >&2
  exit 1
}
[[ -x "${package_dir}/CalendarBridgePrivate" ]] || {
  echo "找不到可执行的 CalendarBridgePrivate。请重新下载完整 Release 压缩包。" >&2
  exit 1
}
[[ -d "${package_dir}/apple-calendar-assistant" ]] || {
  echo "找不到 apple-calendar-assistant Skill。请重新下载完整 Release 压缩包。" >&2
  exit 1
}

/bin/mkdir -p "${HOME}/Applications" "${skill_dir}"
/usr/bin/ditto "${package_dir}/CalendarBridge.app" "${app_dir}"
/usr/bin/ditto "${package_dir}/CalendarBridgePrivate" "${HOME}/Applications/CalendarBridgePrivate"
/usr/bin/ditto "${package_dir}/apple-calendar-assistant" "${skill_dir}"
/bin/chmod 755 "${app_dir}/Contents/MacOS/CalendarBridge"
/bin/chmod 755 "${HOME}/Applications/CalendarBridgePrivate"
/bin/chmod 755 "${skill_dir}/scripts/parse_schedule.py"

echo "已安装：${app_dir}"
echo "已安装：${HOME}/Applications/CalendarBridgePrivate"
echo "已安装 Skill：${skill_dir}"
echo
echo "首次使用前运行："
echo "  echo '{\"action\":\"setup\"}' | '${app_dir}/Contents/MacOS/CalendarBridge'"
echo
echo "注意：此 Release 可能是未签名的实验版本；若 macOS 显示安全提示，请确认下载来源后在 Finder 中右键选择‘打开’。"
