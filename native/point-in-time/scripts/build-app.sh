#!/usr/bin/env bash
# Builds a local pointInTime.app with SwiftPM (Command Line Tools are enough) for development and host checks.
# Signs with $POINT_IN_TIME_SIGN_IDENTITY when set, otherwise ad hoc; always with the hardened runtime.
# Releases do not use this script: they archive the generated Xcode project through scripts/release-macos.mjs.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/build}"
version="$(sed -n 's/.*"MARKETING_VERSION" => "\(.*\)".*/\1/p' "$root/ProjectGenerator.rb" | head -1)"
build_number="$(sed -n 's/.*"CURRENT_PROJECT_VERSION" => "\(.*\)".*/\1/p' "$root/ProjectGenerator.rb" | head -1)"
swift build --package-path "$root" -c release --product PointInTime
bin="$(swift build --package-path "$root" -c release --show-bin-path)"
app="$out/pointInTime.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/PointInTime" "$app/Contents/MacOS/PointInTime"
sed -e 's/$(EXECUTABLE_NAME)/PointInTime/' -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/dev.subset.point-in-time/' \
    -e "s/\$(MARKETING_VERSION)/$version/" -e "s/\$(CURRENT_PROJECT_VERSION)/$build_number/" -e 's/$(MACOSX_DEPLOYMENT_TARGET)/14.0/' \
    "$root/MacApp/Info.plist" > "$app/Contents/Info.plist"
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
cp "$root"/MacApp/Assets.xcassets/AppIcon.appiconset/icon_*.png "$iconset/"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"
codesign --force --options runtime --timestamp=none --entitlements "$root/MacApp/PointInTime.entitlements" \
    --sign "${POINT_IN_TIME_SIGN_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"
echo "$app"
