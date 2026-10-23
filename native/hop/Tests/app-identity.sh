#!/bin/sh
# Checks that the Debug and Release builds of the Hop app target are different apps to macOS: Debug resolves to
# dev.subset.hop.debug and "Hop Debug" and is set up for the team's Apple Development signing, on only when
# scripts/development-signing.sh found that certificate (HOP_DEVELOPMENT_SIGNING_ALLOWED), Release to
# dev.subset.hop and "Hop" with its signing left to release-macos.mjs, and the two never share a bundle ID or a name.
# Reads the resolved build settings of Hop.xcodeproj; given built apps (--debug-app and --release-app, both or
# neither), also checks the values in their Info.plist files. Needs Xcode.
#
#   sh Tests/app-identity.sh [--project path/Hop.xcodeproj] [--debug-app Debug/Hop.app --release-app Release/Hop.app]
set -eu

source_dir="$(cd "$(dirname "$0")/.." && pwd)"
project="$source_dir/Hop.xcodeproj"
debug_app=""
release_app=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) project="$2"; shift 2 ;;
    --debug-app) debug_app="$2"; shift 2 ;;
    --release-app) release_app="$2"; shift 2 ;;
    *) echo "usage: $0 [--project Hop.xcodeproj] [--debug-app Hop.app --release-app Hop.app]" >&2; exit 2 ;;
  esac
done
if { [ -n "$debug_app" ] && [ -z "$release_app" ]; } || { [ -z "$debug_app" ] && [ -n "$release_app" ]; }; then
  echo "pass both --debug-app and --release-app, or neither" >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

# settings <configuration>: records the resolved build settings of the Hop target.
settings() {
  xcodebuild -project "$project" -target Hop -configuration "$1" -showBuildSettings > "$work/$1.settings" 2> "$work/$1.err" \
    || { cat "$work/$1.err" >&2; echo "xcodebuild -showBuildSettings failed for $1" >&2; exit 2; }
}
# setting <configuration> <name>: one resolved build setting, empty when unset.
setting() {
  sed -n "s/^ *$2 = //p" "$work/$1.settings" | head -n 1
}
expect() {
  actual="$(setting "$1" "$2")"
  [ "$actual" = "$3" ] || fail "$1 $2 is '$actual', expected '$3'"
}

settings Debug
settings Release

expect Debug PRODUCT_BUNDLE_IDENTIFIER dev.subset.hop.debug
expect Debug HOP_DISPLAY_NAME "Hop Debug"
expect Debug PRODUCT_NAME Hop
expect Debug DEVELOPMENT_TEAM SAZVPX4CAA
expect Debug CODE_SIGN_STYLE Automatic
expect Debug CODE_SIGN_IDENTITY "Apple Development"
case "$(setting Debug HOP_DEVELOPMENT_SIGNING_ALLOWED)" in YES | NO) ;; *) fail "Debug HOP_DEVELOPMENT_SIGNING_ALLOWED is not YES or NO" ;; esac
expect Debug CODE_SIGNING_ALLOWED "$(setting Debug HOP_DEVELOPMENT_SIGNING_ALLOWED)"

expect Release PRODUCT_BUNDLE_IDENTIFIER dev.subset.hop
expect Release HOP_DISPLAY_NAME Hop
expect Release PRODUCT_NAME Hop
# Release signing belongs to release-macos.mjs, which passes the team and the Developer ID identity itself.
expect Release DEVELOPMENT_TEAM ""
expect Release CODE_SIGN_STYLE Automatic

# Independent of the expected values above, so a later edit that sets both configurations alike still fails here.
for name in PRODUCT_BUNDLE_IDENTIFIER HOP_DISPLAY_NAME; do
  [ "$(setting Debug "$name")" != "$(setting Release "$name")" ] || fail "Debug and Release share $name '$(setting Debug "$name")'"
done

# plist <app> <key>: one value of a built app's Info.plist, empty when absent.
plist() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2> /dev/null || true
}
expect_plist() {
  actual="$(plist "$2" "$3")"
  [ "$actual" = "$4" ] || fail "$1 Info.plist $3 is '$actual', expected '$4'"
}
if [ -n "$debug_app" ]; then
  for app in "$debug_app" "$release_app"; do
    [ -f "$app/Contents/Info.plist" ] || { echo "no Info.plist in $app" >&2; exit 2; }
  done
  expect_plist Debug "$debug_app" CFBundleIdentifier dev.subset.hop.debug
  expect_plist Debug "$debug_app" CFBundleDisplayName "Hop Debug"
  expect_plist Debug "$debug_app" CFBundleName "Hop Debug"
  expect_plist Release "$release_app" CFBundleIdentifier dev.subset.hop
  expect_plist Release "$release_app" CFBundleDisplayName Hop
  expect_plist Release "$release_app" CFBundleName Hop
  for key in CFBundleIdentifier CFBundleDisplayName CFBundleName; do
    [ "$(plist "$debug_app" "$key")" != "$(plist "$release_app" "$key")" ] || fail "the built apps share $key"
  done
  case "$(plist "$debug_app" NSScreenCaptureUsageDescription)" in
    "Hop Debug uses Screen Recording"*) ;;
    *) fail "Debug Info.plist NSScreenCaptureUsageDescription does not name Hop Debug" ;;
  esac
fi

[ "$failures" -eq 0 ] || exit 1
echo "Debug (dev.subset.hop.debug, Hop Debug) and Release (dev.subset.hop, Hop) are separate apps${debug_app:+, in the built Info.plist files too}."
