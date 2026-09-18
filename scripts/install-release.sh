#!/bin/zsh
set -euo pipefail
package_dir="$(cd "$(dirname "$0")" && pwd)"
/usr/bin/codesign --verify --deep --strict "${package_dir}/CalendarBridge.app"
python3 "${package_dir}/apple-calendar-assistant/scripts/install_support.py" --app CalendarBridge --source-app "${package_dir}/CalendarBridge.app" --source-skill "${package_dir}/apple-calendar-assistant" --private "${package_dir}/CalendarBridgePrivate"
