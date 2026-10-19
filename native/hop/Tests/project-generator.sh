#!/bin/sh
# Checks that ProjectGenerator.rb only replaces the files it generates: developer state inside Hop.xcodeproj
# survives regeneration, and a regeneration that fails or is interrupted while installing leaves the previous project
# intact.
# Runs on a copy of native/hop, so the checkout is never touched. Needs the xcodeproj 1.27.0 gem.
set -eu

source_dir="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

rsync -a --exclude .build --exclude .swiftpm --exclude build "$source_dir/" "$work/hop/"
project="$work/hop/Hop.xcodeproj"
pbxproj="$project/project.pbxproj"
scheme="$project/xcshareddata/xcschemes/Hop.xcscheme"
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
    [ -f "$file" ] || fail "$1: lost ${file#"$work/hop/"}"
    grep -qx "developer state $file" "$file" || fail "$1: changed ${file#"$work/hop/"}"
  done
}

# A successful regeneration rewrites the generated files byte for byte and keeps everything else.
(cd "$work/hop" && ruby ProjectGenerator.rb > /dev/null)
assert_developer_state "regeneration"
cmp -s "$pbxproj" "$work/expected.pbxproj" || fail "regeneration changed project.pbxproj"
cmp -s "$scheme" "$work/expected.xcscheme" || fail "regeneration changed the shared scheme"
[ -z "$(find "$work/hop" -maxdepth 1 -name 'Hop-xcodeproj*')" ] || fail "regeneration left its staging folder"

# Make the scheme install fail after project.pbxproj has been replaced: the generator must exit non-zero and put the
# previous project.pbxproj back.
echo "// previous project" >> "$pbxproj"
cp "$pbxproj" "$work/previous.pbxproj"
chmod a-w "$project/xcshareddata/xcschemes"
if err="$(cd "$work/hop" && ruby ProjectGenerator.rb 2>&1 > /dev/null)"; then
  fail "regeneration succeeded although the scheme could not be installed"
fi
chmod u+w "$project/xcshareddata/xcschemes"
# Any other failure (a crash before the install) would leave the project untouched and pass the checks below.
case "$err" in *"Permission denied"*) ;; *) fail "regeneration failed for another reason: $err" ;; esac
cmp -s "$pbxproj" "$work/previous.pbxproj" || fail "failed regeneration did not restore project.pbxproj"
cmp -s "$scheme" "$work/expected.xcscheme" || fail "failed regeneration changed the shared scheme"
assert_developer_state "failed regeneration"
[ -z "$(find "$work/hop" -maxdepth 1 -name 'Hop-xcodeproj*')" ] || fail "failed regeneration left its staging folder"

# Interrupt the install (Ctrl-C, then SIGTERM) right after the scheme has been replaced, the last file installed: the
# generator must put both previous files back before exiting.
cat > "$work/interrupt.rb" <<'RUBY'
class << File
  alias_method :hop_test_rename, :rename
  def rename(from, to)
    result = hop_test_rename(from, to)
    if !$hop_test_interrupted && to.end_with?("xcschemes/Hop.xcscheme")
      $hop_test_interrupted = true
      raise SignalException, ENV.fetch("HOP_TEST_SIGNAL")
    end
    result
  end
end
RUBY
echo "<!-- previous scheme -->" >> "$scheme"
cp "$scheme" "$work/previous.xcscheme"
for signal in INT:130 TERM:143; do
  want="${signal#*:}"
  signal="${signal%:*}"
  # Ruby re-raises an unhandled signal, so the generator dies of that signal (status 128 + its number). The outer
  # redirection also hides the shell's own "Terminated" report.
  status=0
  { (cd "$work/hop" && HOP_TEST_SIGNAL="$signal" exec ruby -r "$work/interrupt.rb" ProjectGenerator.rb > /dev/null) \
    || status=$?; } 2> /dev/null
  [ "$status" -eq "$want" ] || fail "SIG$signal regeneration exited $status, expected $want"
  cmp -s "$pbxproj" "$work/previous.pbxproj" || fail "SIG$signal regeneration did not restore project.pbxproj"
  cmp -s "$scheme" "$work/previous.xcscheme" || fail "SIG$signal regeneration did not restore the shared scheme"
  assert_developer_state "SIG$signal regeneration"
  [ -z "$(find "$work/hop" -maxdepth 1 -name 'Hop-xcodeproj*')" ] || fail "SIG$signal regeneration left its staging folder"
done

echo "ProjectGenerator.rb keeps developer state and restores the project on failure or interruption."
