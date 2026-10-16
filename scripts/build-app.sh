#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="release"
if [[ "${1:-}" == "--debug" ]]; then
    configuration="debug"
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--debug]" >&2
    exit 2
fi

swift build --package-path "$project_dir" -c "$configuration" --product ASCBridge
binary_dir="$(swift build --package-path "$project_dir" -c "$configuration" --show-bin-path)"
app_path="$project_dir/dist/ASC Bridge.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/ASCBridge" "$app_path/Contents/MacOS/ASCBridge"
cp "$project_dir/Resources/Info.plist" "$app_path/Contents/Info.plist"
swift "$project_dir/scripts/make-icon.swift" "$project_dir/dist/AppIcon.iconset"
iconutil -c icns "$project_dir/dist/AppIcon.iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
codesign --force --sign "${ASC_BRIDGE_SIGN_IDENTITY:--}" --options runtime "$app_path"
codesign --verify --strict "$app_path"
echo "Gotowe: $app_path"

