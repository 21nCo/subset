#!/bin/sh
# Checks scripts/check-private-symbols.sh against binaries with known undefined symbols: it must fail on each
# forbidden private API, pass on public CoreGraphics names that only look similar, check every Mach-O inside an app
# bundle, and report unreadable input as an error rather than a pass. Also checks the recorded `nm -u` listing of
# the shell (Tests/Fixtures/shell-undefined-symbols.txt, from an unsigned Debug build of Hop.app and libHopCore.a)
# passes, and fails once _CGSCopyWindowProperty is added to it. Needs only the C compiler from Command Line Tools.
set -eu

source_dir="$(cd "$(dirname "$0")/.." && pwd)"
check="$source_dir/scripts/check-private-symbols.sh"
shell_listing="$source_dir/Tests/Fixtures/shell-undefined-symbols.txt"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# expect <status> <description> <check arguments>...
expect() {
  want="$1"
  what="$2"
  shift 2
  status=0
  sh "$check" "$@" > "$work/out" 2>&1 || status=$?
  [ "$status" -eq "$want" ] || { cat "$work/out" >&2; fail "$what: exit $status, expected $want"; }
}

# object <name> <C function declarations and calls>: compiles an object file whose undefined symbols are the
# functions it calls. Nothing is linked, so the private frameworks need not exist.
object() {
  printf '%s\n' "$2" > "$work/$1.c"
  cc -c -o "$work/$1.o" "$work/$1.c"
}

object public 'void CGShadingRelease(void *); void *CGSessionCopyCurrentDictionary(void);
int CGSizeMakeWithDictionaryRepresentation(void *, void *); int CGSetDisplayTransferByFormula(void);
void *CGWindowListCopyWindowInfo(int, int); int AXUIElementCopyAttributeValue(void *, void *, void **);
void use(void) { CGShadingRelease(0); CGSessionCopyCurrentDictionary(); CGSizeMakeWithDictionaryRepresentation(0, 0);
  CGSetDisplayTransferByFormula(); CGWindowListCopyWindowInfo(0, 0); AXUIElementCopyAttributeValue(0, 0, 0); }'
object cgs 'void *CGSCopyWindowProperty(int, int, void *, void **); void use(void) { CGSCopyWindowProperty(0, 0, 0, 0); }'
object sls 'int SLSMainConnectionID(void); void use(void) { SLSMainConnectionID(); }'
object ax 'int _AXUIElementGetWindow(void *, unsigned *); void use(void) { _AXUIElementGetWindow(0, 0); }'

nm -u "$work/public.o" | grep -q '^_CGShadingRelease$' || fail "the public fixture does not reference _CGShadingRelease"
expect 0 "public CoreGraphics and Accessibility functions" "$work/public.o"
for name in cgs sls ax; do
  expect 1 "$name fixture" "$work/$name.o"
done
expect 1 "public and private objects together" "$work/public.o" "$work/cgs.o"
grep -q '^  _CGSCopyWindowProperty$' "$work/out" || fail "the report does not name _CGSCopyWindowProperty"

# A static library is checked through its members.
ar -rc "$work/libmixed.a" "$work/public.o" "$work/sls.o" 2> /dev/null
expect 1 "static library with a private member" "$work/libmixed.a"

# In an app bundle the main executable can be a stub: a Debug build keeps the app's code in Hop.debug.dylib.
app="$work/Fixture.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
cp "$work/public.o" "$app/MacOS/Hop"
echo '<plist/>' > "$app/Info.plist"
expect 0 "bundle with only public symbols" "$work/Fixture.app"
cp "$work/ax.o" "$app/MacOS/Hop.debug.dylib"
expect 1 "bundle whose second binary links _AXUIElementGetWindow" "$work/Fixture.app"

# Missing or unreadable input is an error, never a pass.
expect 2 "no arguments"
expect 2 "missing file" "$work/missing"
expect 2 "a file nm cannot read" "$app/Info.plist"
expect 2 "a folder without Mach-O files" "$app/Resources"
expect 2 "missing listing" --listing "$work/missing"

# The recorded listing of the shell passes; the same listing with one private symbol added fails.
expect 0 "the shell's recorded listing" --listing "$shell_listing"
{ cat "$shell_listing"; echo '_CGSCopyWindowProperty'; } > "$work/shell-plus-cgs.txt"
expect 1 "the shell's listing plus _CGSCopyWindowProperty" --listing "$work/shell-plus-cgs.txt"
grep -q '^  _CGSCopyWindowProperty$' "$work/out" || fail "the listing report does not name _CGSCopyWindowProperty"

echo "check-private-symbols.sh fails on private API symbols and passes on the shell."
