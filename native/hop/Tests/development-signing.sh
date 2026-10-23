#!/bin/sh
# Tests scripts/development-signing.sh against a stand-in keychain (a fake `security` first on PATH, with real
# certificates made by openssl): a Debug build is team-signed only when a valid Apple Development identity of the
# Debug team is present, and other configurations leave the setting alone. Given a Debug app built by the Hop scheme
# with signing left on, on a Mac without the team's Apple Development certificate (--debug-app), also checks that the
# build came out unsigned and is still dev.subset.hop.debug.
#
#   sh Tests/development-signing.sh [--debug-app Debug/Hop.app]
set -eu

source_dir="$(cd "$(dirname "$0")/.." && pwd)"
script="$source_dir/scripts/development-signing.sh"
debug_app=""
while [ $# -gt 0 ]; do
  case "$1" in
    --debug-app) debug_app="$2"; shift 2 ;;
    *) echo "usage: $0 [--debug-app Hop.app]" >&2; exit 2 ;;
  esac
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

mkdir "$work/bin"
cat > "$work/bin/security" << 'EOF'
#!/bin/sh
case "$1" in
  find-identity) cat "$FAKE_KEYCHAIN/identities" ;;
  find-certificate) cat "$FAKE_KEYCHAIN/certificates" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$work/bin/security"
export FAKE_KEYCHAIN="$work/keychain"

# keychain: empties the stand-in keychain.
keychain() {
  rm -rf "$FAKE_KEYCHAIN"
  mkdir "$FAKE_KEYCHAIN"
  : > "$FAKE_KEYCHAIN/identities"
  : > "$FAKE_KEYCHAIN/certificates"
}
# certificate <common name> <team> <valid|invalid>: adds a certificate; a valid one is also listed as an identity.
certificate() {
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$1/OU=$2/O=Test" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2> /dev/null
  hash="$(openssl x509 -noout -fingerprint -sha1 -in "$work/cert.pem" | sed 's/.*=//; s/://g')"
  { echo "SHA-256 hash: 0000"; echo "SHA-1 hash: $hash"; cat "$work/cert.pem"; } >> "$FAKE_KEYCHAIN/certificates"
  [ "$3" = valid ] && echo "  1) $hash \"$1\"" >> "$FAKE_KEYCHAIN/identities"
  return 0
}
# decide <configuration> <team> <expected: YES, NO or absent> <case>
decide() {
  rm -f "$work/out.xcconfig"
  PATH="$work/bin:$PATH" CONFIGURATION="$1" DEVELOPMENT_TEAM="$2" sh "$script" "$work/out.xcconfig" \
    || fail "$4: the script exited non-zero"
  if [ -f "$work/out.xcconfig" ]; then actual="$(cat "$work/out.xcconfig")"; else actual=absent; fi
  case "$3" in
    absent) expected=absent ;;
    *) expected="HOP_DEVELOPMENT_SIGNING_ALLOWED = $3" ;;
  esac
  [ "$actual" = "$expected" ] || fail "$4: wrote '$actual', expected '$expected'"
}

keychain
decide Debug SAZVPX4CAA NO "no identities"
certificate "Developer ID Application: Test (SAZVPX4CAA)" SAZVPX4CAA valid
decide Debug SAZVPX4CAA NO "only a Developer ID identity of the team"
certificate "Apple Development: Test (AB12CD34EF)" OTHERTEAM1 valid
decide Debug SAZVPX4CAA NO "an Apple Development identity of another team"
certificate "Apple Development: Test (AB12CD34EF)" SAZVPX4CAA invalid
decide Debug SAZVPX4CAA NO "the team's Apple Development certificate without a valid identity"
decide Debug SAZVPX4CA NO "a team ID that is only a prefix of the certificate's"
certificate "Apple Development: Test (AB12CD34EF)" SAZVPX4CAA valid
decide Debug SAZVPX4CAA YES "a valid Apple Development identity of the team"
decide Debug "" NO "no DEVELOPMENT_TEAM"
decide Release SAZVPX4CAA absent "a Release build"

# The file is rewritten when the answer changes and left alone when it does not.
PATH="$work/bin:$PATH" CONFIGURATION=Debug DEVELOPMENT_TEAM=SAZVPX4CAA sh "$script" "$work/out.xcconfig"
touch -t 202001010000 "$work/out.xcconfig"
before="$(stat -f %m "$work/out.xcconfig")"
PATH="$work/bin:$PATH" CONFIGURATION=Debug DEVELOPMENT_TEAM=SAZVPX4CAA sh "$script" "$work/out.xcconfig"
[ "$(stat -f %m "$work/out.xcconfig")" = "$before" ] || fail "an unchanged answer rewrote the file"
keychain
PATH="$work/bin:$PATH" CONFIGURATION=Debug DEVELOPMENT_TEAM=SAZVPX4CAA sh "$script" "$work/out.xcconfig"
[ "$(cat "$work/out.xcconfig")" = "HOP_DEVELOPMENT_SIGNING_ALLOWED = NO" ] || fail "a removed certificate left signing on"

if [ -n "$debug_app" ]; then
  [ -f "$debug_app/Contents/Info.plist" ] || { echo "no Info.plist in $debug_app" >&2; exit 2; }
  id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$debug_app/Contents/Info.plist")"
  [ "$id" = dev.subset.hop.debug ] || fail "the built Debug app is '$id', expected dev.subset.hop.debug"
  # Unsigned: at most the linker's ad-hoc signature on the executable, no team and no sealed bundle.
  signature="$(codesign -dv "$debug_app" 2>&1 || true)"
  case "$signature" in
    *"not signed at all"* | *"TeamIdentifier=not set"*) ;;
    *) fail "the built Debug app is signed: $signature" ;;
  esac
  [ ! -e "$debug_app/Contents/_CodeSignature" ] || fail "the built Debug app has a code signature"
fi

[ "$failures" -eq 0 ] || exit 1
echo "Debug builds are team-signed only with the team's Apple Development identity${debug_app:+; the built Debug app is unsigned}."
