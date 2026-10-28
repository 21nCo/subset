#!/bin/sh
# Checks that the built app weak-links FoundationModels, so it still launches on macOS 14 and 15, which do not have the
# framework: every Mach-O in Contents/MacOS and Contents/Helpers (the subset-system helper) that loads it must load it
# weakly (LC_LOAD_WEAK_DYLIB), and one must.
# Usage: sh Tests/weak-link.sh "<path to Subset System.app>"
set -eu

app="$1"
fail() { echo "FAIL: $1" >&2; exit 1; }

weak=0
for binary in "$app"/Contents/MacOS/* "$app"/Contents/Helpers/*; do
    [ -f "$binary" ] || continue
    file "$binary" | grep -q 'Mach-O' || continue
    commands="$(otool -l "$binary" | grep -B2 '/FoundationModels.framework/' | grep ' cmd ' || true)"
    if printf '%s\n' "$commands" | grep -q ' cmd LC_LOAD_DYLIB$'; then
        fail "$binary links FoundationModels strongly; it would not launch before macOS 26"
    fi
    if printf '%s\n' "$commands" | grep -q ' cmd LC_LOAD_WEAK_DYLIB$'; then weak=1; fi
done
[ "$weak" = 1 ] || fail "no binary in $app weak-links FoundationModels"
echo "FoundationModels is weak-linked in $app"
