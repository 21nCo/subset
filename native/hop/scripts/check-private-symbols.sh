#!/bin/sh
# Fails if Hop links a private macOS API: CoreGraphics server (CGS*) or SkyLight (SLS*) functions, or
# _AXUIElementGetWindow. Hop uses public APIs only (shared decision on SET-89).
#
#   sh scripts/check-private-symbols.sh <Hop.app | binary | static library>...
#   sh scripts/check-private-symbols.sh --listing <recorded `nm -u` output>...
#
# For an app bundle, every Mach-O file inside it is checked, not just Contents/MacOS/Hop: a Debug build keeps the
# app's code in Contents/MacOS/Hop.debug.dylib. Matching is on symbol names, so public CoreGraphics functions whose
# names merely start with CGS (CGShading*, CGSession*, CGSize*, CGSetDisplay*) pass: a forbidden name continues with
# an uppercase letter. A symbol resolved at run time with dlsym does not appear in `nm -u` and is not caught here.
#
# Exit status: 0 when nothing forbidden is linked, 1 when a forbidden symbol is found, 2 for a usage error or a
# file that cannot be read.
set -eu

forbidden='^(_(CGS|SLS)[A-Z]|__?AXUIElementGetWindow$)'

usage() {
  echo "usage: $0 <Hop.app | binary | static library>... | --listing <nm -u output>..." >&2
  exit 2
}

found=0

# check <label> <undefined-symbol listing>
check() {
  matches="$(printf '%s\n' "$2" | sed 's/^[[:space:]]*//' | grep -E "$forbidden" | sort -u || true)"
  if [ -n "$matches" ]; then
    echo "$1 links private macOS API symbols:" >&2
    printf '%s\n' "$matches" | sed 's/^/  /' >&2
    found=1
  else
    echo "ok: $1"
  fi
}

# macho_files <folder>: the Mach-O files in a folder, one per line.
macho_files() {
  find "$1" -type f -print | sort | while IFS= read -r file; do
    case "$(file -b "$file")" in
      Mach-O*) printf '%s\n' "$file" ;;
    esac
  done
}

# check_binary <Mach-O file or static library>
check_binary() {
  if ! listing="$(nm -u "$1")"; then
    echo "nm could not read $1" >&2
    exit 2
  fi
  check "$1" "$listing"
}

[ $# -gt 0 ] || usage
if [ "$1" = "--listing" ]; then
  shift
  [ $# -gt 0 ] || usage
  for file in "$@"; do
    [ -f "$file" ] || { echo "no such listing: $file" >&2; exit 2; }
    check "$file" "$(cat "$file")"
  done
else
  for path in "$@"; do
    if [ -d "$path" ]; then
      binaries="$(macho_files "$path")"
      [ -n "$binaries" ] || { echo "no Mach-O files in $path" >&2; exit 2; }
      # A here-document keeps the loop in this shell, so check can record what it found.
      while IFS= read -r binary; do
        check_binary "$binary"
      done <<EOF
$binaries
EOF
    elif [ -f "$path" ]; then
      check_binary "$path"
    else
      echo "no such file: $path" >&2
      exit 2
    fi
  done
fi

exit "$found"
