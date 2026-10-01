#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
output_dir=${1:-$project_dir/dist}
identity=${MGRAPH_SIGN_IDENTITY:--}

swift build --package-path "$project_dir" --configuration release >&2
binary=$(swift build --package-path "$project_dir" --configuration release --show-bin-path)/MGraphCapture
bundle="$output_dir/MGraphCapture.app"
rm -rf -- "$bundle"
mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources"
cp "$project_dir/Info.plist" "$bundle/Contents/Info.plist"
cp "$project_dir/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
cp "$binary" "$bundle/Contents/MacOS/MGraphCapture"
chmod 755 "$bundle/Contents/MacOS/MGraphCapture"

if [[ "$identity" == '-' ]]; then
  codesign --force --sign - "$bundle" >&2
else
  codesign --force --options runtime --sign "$identity" "$bundle" >&2
fi
codesign --verify --deep --strict --verbose=2 "$bundle" >&2
if spctl --assess --type execute --verbose=2 "$bundle" >&2; then
  print -- "Gatekeeper assessment: accepted" >&2
else
  print -- "Gatekeeper assessment: rejected (development builds are not notarized)" >&2
fi
otool -L "$bundle/Contents/MacOS/MGraphCapture" >&2
print -r -- "$bundle"
