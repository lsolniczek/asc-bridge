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
if [[ ! -s "$project_dir/LICENSE" ]]; then
    echo "Missing project LICENSE; refusing to package the app without license notices." >&2
    exit 1
fi
python3 "$project_dir/scripts/update-third-party-notices.py" --check
binary_dir="$(swift build --package-path "$project_dir" -c "$configuration" --show-bin-path)"
app_path="$project_dir/dist/ASC Bridge.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/ASCBridge" "$app_path/Contents/MacOS/ASCBridge"
cp "$project_dir/Resources/Info.plist" "$app_path/Contents/Info.plist"
for resource_bundle in "$binary_dir"/*.bundle; do
    if [[ -d "$resource_bundle" ]]; then
        cp -Rf "$resource_bundle" "$app_path/Contents/Resources/"
    fi
done
cp -f "$project_dir/LICENSE" "$app_path/Contents/Resources/LICENSE"
cp -f "$project_dir/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
swift "$project_dir/scripts/make-icon.swift" "$project_dir/dist/AppIcon.iconset"
iconutil -c icns "$project_dir/dist/AppIcon.iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
codesign --force --sign "${ASC_BRIDGE_SIGN_IDENTITY:--}" --options runtime "$app_path"
codesign --verify --strict "$app_path"
echo "Gotowe: $app_path"

