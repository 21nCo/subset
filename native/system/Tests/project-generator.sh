#!/bin/sh
# Checks that ProjectGenerator.rb only replaces the files it generates: developer state inside System.xcodeproj
# survives regeneration, and a regeneration that fails while installing leaves the previous project intact.
# Runs on a copy of native/system, so the checkout is never touched. Needs the xcodeproj 1.27.0 gem.
set -eu

source_dir="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

rsync -a --exclude .build --exclude .swiftpm --exclude build "$source_dir/" "$work/system/"
project="$work/system/System.xcodeproj"
pbxproj="$project/project.pbxproj"
scheme="$project/xcshareddata/xcschemes/SubsetSystem.xcscheme"
cp "$pbxproj" "$work/expected.pbxproj"
cp "$scheme" "$work/expected.xcscheme"

breakpoints="$project/xcuserdata/dev.xcuserdatad/xcdebugger/Breakpoints_v2.xcbkptlist"
personal_scheme="$project/xcuserdata/dev.xcuserdatad/xcschemes/Personal.xcscheme"
workspace="$project/project.xcworkspace/contents.xcworkspacedata"
ui_state="$project/project.xcworkspace/xcuserdata/dev.xcuserdatad/UserInterfaceState.xcuserstate"
for file in "$breakpoints" "$personal_scheme" "$workspace" "$ui_state"; do
  mkdir -p "$(dirname "$file")"
  echo "developer state $file" > "$file"
done

assert_developer_state() {
  for file in "$breakpoints" "$personal_scheme" "$workspace" "$ui_state"; do
    [ -f "$file" ] || fail "$1: lost ${file#"$work/system/"}"
    grep -qx "developer state $file" "$file" || fail "$1: changed ${file#"$work/system/"}"
  done
}

# A successful regeneration rewrites the generated files byte for byte and keeps everything else.
(cd "$work/system" && ruby ProjectGenerator.rb > /dev/null)
assert_developer_state "regeneration"
cmp -s "$pbxproj" "$work/expected.pbxproj" || fail "regeneration changed project.pbxproj"
cmp -s "$scheme" "$work/expected.xcscheme" || fail "regeneration changed the shared scheme"
[ -z "$(find "$work/system" -maxdepth 1 -name 'System-xcodeproj*')" ] || fail "regeneration left its staging folder"

# Make the scheme install fail after project.pbxproj has been replaced: the generator must exit non-zero and put the
# previous project.pbxproj back.
echo "// previous project" >> "$pbxproj"
cp "$pbxproj" "$work/previous.pbxproj"
chmod a-w "$project/xcshareddata/xcschemes"
if (cd "$work/system" && ruby ProjectGenerator.rb > /dev/null 2>&1); then
  fail "regeneration succeeded although the scheme could not be installed"
fi
chmod u+w "$project/xcshareddata/xcschemes"
cmp -s "$pbxproj" "$work/previous.pbxproj" || fail "failed regeneration did not restore project.pbxproj"
cmp -s "$scheme" "$work/expected.xcscheme" || fail "failed regeneration changed the shared scheme"
assert_developer_state "failed regeneration"
[ -z "$(find "$work/system" -maxdepth 1 -name 'System-xcodeproj*')" ] || fail "failed regeneration left its staging folder"

echo "ProjectGenerator.rb keeps developer state and restores the project on failure."
