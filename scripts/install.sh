#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/bridge-install.XXXXXX")"
trap '/bin/rm -rf "${stage}"' EXIT
/usr/bin/swift build -c release --package-path "${project_dir}"
/bin/mkdir -p "${stage}/CalendarBridge.app/Contents/MacOS"
/usr/bin/ditto "${project_dir}/.build/release/CalendarBridge" "${stage}/CalendarBridge.app/Contents/MacOS/CalendarBridge"
/usr/bin/ditto "${project_dir}/Resources/Info.plist" "${stage}/CalendarBridge.app/Contents/Info.plist"
/usr/bin/clang -fobjc-arc -O -F/System/Library/PrivateFrameworks -framework Foundation -framework ReminderKit "${project_dir}/Tools/CalendarBridgePrivate.m" -o "${stage}/CalendarBridgePrivate"
/usr/bin/codesign --force --deep --sign - "${stage}/CalendarBridge.app"
/usr/bin/codesign --verify --deep --strict "${stage}/CalendarBridge.app"
python3 "${project_dir}/skill/apple-calendar-assistant/scripts/install_support.py" --app CalendarBridge --source-app "${stage}/CalendarBridge.app" --source-skill "${project_dir}/skill/apple-calendar-assistant" --private "${stage}/CalendarBridgePrivate"
