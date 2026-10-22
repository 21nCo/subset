#!/usr/bin/env bash
# Builds a local pointInTime.app with SwiftPM (Command Line Tools are enough) for development and host checks, with
# the read-only `point-in-time` command at Contents/Helpers/point-in-time.
# Signs with $POINT_IN_TIME_SIGN_IDENTITY when set, otherwise ad hoc; always with the hardened runtime.
# Releases do not use this script: they archive the generated Xcode project through scripts/release-macos.mjs.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/build}"
# ProjectGenerator.rb sets them as config.build_settings["MARKETING_VERSION"] = "0.1.0".
version="$(sed -n 's/.*\["MARKETING_VERSION"\] = "\([^"]*\)".*/\1/p' "$root/ProjectGenerator.rb" | head -1)"
build_number="$(sed -n 's/.*\["CURRENT_PROJECT_VERSION"\] = "\([^"]*\)".*/\1/p' "$root/ProjectGenerator.rb" | head -1)"
if [ -z "$version" ] || [ -z "$build_number" ]; then
  echo "Could not read MARKETING_VERSION and CURRENT_PROJECT_VERSION from ProjectGenerator.rb" >&2
  exit 1
fi
swift build --package-path "$root" -c release --product PointInTime
swift build --package-path "$root" -c release --product point-in-time
bin="$(swift build --package-path "$root" -c release --show-bin-path)"
app="$out/pointInTime.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp "$bin/PointInTime" "$app/Contents/MacOS/PointInTime"
cp "$bin/point-in-time" "$app/Contents/Helpers/point-in-time"
sed -e 's/$(EXECUTABLE_NAME)/PointInTime/' -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/dev.subset.point-in-time/' \
    -e "s/\$(MARKETING_VERSION)/$version/" -e "s/\$(CURRENT_PROJECT_VERSION)/$build_number/" -e 's/$(MACOSX_DEPLOYMENT_TARGET)/14.0/' \
    "$root/MacApp/Info.plist" > "$app/Contents/Info.plist"
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
cp "$root"/MacApp/Assets.xcassets/AppIcon.appiconset/icon_*.png "$iconset/"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"
# Nested code is signed before the bundle that contains it. The command needs no entitlements.
codesign --force --options runtime --timestamp=none --identifier dev.subset.point-in-time.cli \
    --sign "${POINT_IN_TIME_SIGN_IDENTITY:--}" "$app/Contents/Helpers/point-in-time"
codesign --force --options runtime --timestamp=none --entitlements "$root/MacApp/PointInTime.entitlements" \
    --sign "${POINT_IN_TIME_SIGN_IDENTITY:--}" "$app"
codesign --verify --deep --strict "$app"
echo "$app"
