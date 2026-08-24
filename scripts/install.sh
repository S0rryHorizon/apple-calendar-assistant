#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="${HOME}/Applications/CalendarBridge.app"
skill_root="${CODEX_HOME:-${HOME}/.codex}/skills"
skill_dir="${skill_root}/apple-calendar-assistant"

/usr/bin/swift build -c release --package-path "${project_dir}"
/bin/mkdir -p "${app_dir}/Contents/MacOS" "${skill_dir}"
/usr/bin/ditto "${project_dir}/.build/release/CalendarBridge" "${app_dir}/Contents/MacOS/CalendarBridge"
/usr/bin/clang -fobjc-arc -O -F/System/Library/PrivateFrameworks \
  -framework Foundation -framework ReminderKit \
  "${project_dir}/Tools/CalendarBridgePrivate.m" \
  -o "${HOME}/Applications/CalendarBridgePrivate"
/usr/bin/ditto "${project_dir}/Resources/Info.plist" "${app_dir}/Contents/Info.plist"
/bin/chmod 755 "${app_dir}/Contents/MacOS/CalendarBridge"
/bin/chmod 755 "${HOME}/Applications/CalendarBridgePrivate"
/usr/bin/codesign --force --deep --sign - "${app_dir}"
/usr/bin/ditto "${project_dir}/skill/apple-calendar-assistant" "${skill_dir}"
/bin/chmod 755 "${skill_dir}/scripts/parse_schedule.py"

echo "Installed app: ${app_dir}"
echo "Installed native Early Reminder helper: ${HOME}/Applications/CalendarBridgePrivate"
echo "Installed skill: ${skill_dir}"
echo "Run setup when ready:"
echo "  echo '{\"action\":\"setup\"}' | '${app_dir}/Contents/MacOS/CalendarBridge'"
