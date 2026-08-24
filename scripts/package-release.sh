#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
plist="${project_dir}/Resources/Info.plist"
version="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}")}"
architecture="${ARCHITECTURE:-$(uname -m)}"
case "${architecture}" in
  arm64|aarch64) architecture="arm64" ;;
  x86_64|amd64) architecture="x86_64" ;;
  *) echo "不支持的架构：${architecture}" >&2; exit 2 ;;
esac

signature_label="unsigned"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  signature_label="signed"
fi
release_name="CalendarBridge-${version}-macos-${architecture}-${signature_label}"
dist_dir="${project_dir}/dist"
temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/calendar-bridge-release.XXXXXX")"
stage_dir="${temp_dir}/${release_name}"
app_dir="${stage_dir}/CalendarBridge.app"
trap '/bin/rm -rf "${temp_dir}"' EXIT

/bin/mkdir -p "${app_dir}/Contents/MacOS" "${dist_dir}"
/usr/bin/swift build -c release --package-path "${project_dir}"
/usr/bin/clang -fobjc-arc -O -F/System/Library/PrivateFrameworks \
  -framework Foundation -framework ReminderKit \
  "${project_dir}/Tools/CalendarBridgePrivate.m" \
  -o "${stage_dir}/CalendarBridgePrivate"
/usr/bin/ditto "${project_dir}/.build/release/CalendarBridge" "${app_dir}/Contents/MacOS/CalendarBridge"
/usr/bin/ditto "${plist}" "${app_dir}/Contents/Info.plist"
/usr/bin/ditto "${project_dir}/skill/apple-calendar-assistant" "${stage_dir}/apple-calendar-assistant"
/usr/bin/ditto "${project_dir}/README.md" "${stage_dir}/README.md"
/usr/bin/ditto "${project_dir}/LICENSE" "${stage_dir}/LICENSE"
/usr/bin/ditto "${project_dir}/docs" "${stage_dir}/docs"
/usr/bin/ditto "${project_dir}/scripts/install-release.sh" "${stage_dir}/install-release.sh"
/bin/chmod 755 "${app_dir}/Contents/MacOS/CalendarBridge" "${stage_dir}/CalendarBridgePrivate" "${stage_dir}/install-release.sh"
/bin/chmod 755 "${stage_dir}/apple-calendar-assistant/scripts/parse_schedule.py"

# A Developer ID can be supplied by a maintainer for a distributable build.
# Without it, use an explicit ad-hoc signature so the app bundle remains
# structurally signed while the artifact is clearly labelled unsigned.
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${stage_dir}/CalendarBridgePrivate"
  /usr/bin/codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${app_dir}"
else
  /usr/bin/codesign --force --sign - "${stage_dir}/CalendarBridgePrivate"
  /usr/bin/codesign --force --deep --sign - "${app_dir}"
fi

zip_path="${dist_dir}/${release_name}.zip"
checksum_path="${zip_path}.sha256"
/bin/rm -f "${zip_path}" "${checksum_path}"
/usr/bin/ditto -c -k --norsrc --keepParent "${stage_dir}" "${zip_path}"
(
  cd "${dist_dir}"
  /usr/bin/shasum -a 256 "${release_name}.zip" > "${release_name}.zip.sha256"
)

echo "Created: ${zip_path}"
echo "Created: ${checksum_path}"
