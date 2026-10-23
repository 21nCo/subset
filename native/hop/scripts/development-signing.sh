#!/bin/sh
# Decides whether a Debug build of Hop is signed. The Hop scheme runs this before every build (a pre-action that
# ProjectGenerator.rb sets up), with the app target's build settings in the environment. For a Debug build it writes
# HOP_DEVELOPMENT_SIGNING_ALLOWED to MacApp/DevelopmentSigning.local.xcconfig, which MacApp/DevelopmentSigning.xcconfig
# includes: YES when the keychain holds a valid Apple Development identity whose certificate belongs to
# DEVELOPMENT_TEAM, otherwise NO. So a Debug build on a Mac with the team's development certificate is team-signed, and
# one on a Mac without it is built unsigned instead of failing. Any other configuration leaves the file alone; Release
# signing belongs to release-macos.mjs.
#
#   CONFIGURATION=Debug DEVELOPMENT_TEAM=<team> sh scripts/development-signing.sh [output.xcconfig]
set -u

[ "${CONFIGURATION:-}" = Debug ] || exit 0
output="${1:-$(cd "$(dirname "$0")/.." && pwd)/MacApp/DevelopmentSigning.local.xcconfig}"
team="${DEVELOPMENT_TEAM:-}"

allowed=NO
if [ -n "$team" ]; then
  # find-identity -v lists only identities with a private key and a valid certificate. Their names carry the
  # developer's own ID, not the team, so the team is read from each certificate's subject (OU).
  hashes="$(security find-identity -v -p codesigning 2> /dev/null \
    | sed -n 's/^ *[0-9][0-9]*) \([0-9A-F]\{40\}\) "Apple Development: .*/\1/p')"
  for hash in $hashes; do
    if security find-certificate -a -Z -p -c "Apple Development" 2> /dev/null \
      | awk -v hash="$hash" '
          /^SHA-1 hash: / { wanted = ($3 == hash) }
          wanted && /^-----BEGIN CERTIFICATE-----/ { printing = 1 }
          printing { print }
          printing && /^-----END CERTIFICATE-----/ { printing = 0; wanted = 0 }' \
      | openssl x509 -noout -subject 2> /dev/null \
      | grep -Eq "(^|[ ,/])OU ?= ?$team([ ,/]|\$)"; then
      allowed=YES
      break
    fi
  done
fi

# Rewritten only when the answer changes, so an unchanged answer does not touch the build's inputs.
content="HOP_DEVELOPMENT_SIGNING_ALLOWED = $allowed"
[ -f "$output" ] && [ "$(cat "$output")" = "$content" ] && exit 0
printf '%s\n' "$content" > "$output.tmp" && mv -f "$output.tmp" "$output"
