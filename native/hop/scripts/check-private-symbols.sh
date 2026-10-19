#!/bin/sh
# Fails if Hop links a private macOS API: CoreGraphics server (CGS*) or SkyLight (SLS*) functions, or
# _AXUIElementGetWindow. Hop uses public APIs only (shared decision on SET-89).
#
#   sh scripts/check-private-symbols.sh <Hop.app | binary | static library>...
#   sh scripts/check-private-symbols.sh --listing <recorded `nm -u` output>...
#
# For an app bundle, every Mach-O file inside it is checked, not just Contents/MacOS/Hop: a Debug build keeps the
# app's code in Contents/MacOS/Hop.debug.dylib. Matching is on symbol names after any number of leading underscores
# (a C function already named _CGSDefaultConnection is __CGSDefaultConnection in nm), so public CoreGraphics
# functions whose names merely start with CGS (CGShading*, CGSession*, CGSize*, CGSetDisplay*) pass: a forbidden
# name continues with an uppercase letter. A symbol resolved at run time with dlsym does not appear in `nm -u` and is not caught here.
#
# Exit status: 0 when nothing forbidden is linked, 1 when a forbidden symbol is found, 2 for a usage error, a
# file or folder that cannot be read completely, or a bundle path containing a newline.
set -eu

forbidden='^(_+(CGS|SLS)[A-Z]|_+AXUIElementGetWindow$)'

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

newline='
'

# macho_files <folder>: the Mach-O files in a folder, one per line. Exits 2 when any part of the folder cannot be
# listed or any file in it cannot be read, so a hidden binary is never skipped. Paths travel one per line, so a name
# containing a newline (which would split into fragments that hide the binary) is an error too.
macho_files() {
  case "$1" in *"$newline"*) echo "cannot check $1: its path contains a newline" >&2; exit 2 ;; esac
  if ! named="$(find "$1" -name "*$newline*" -print)"; then
    echo "could not list every file in $1" >&2
    exit 2
  fi
  if [ -n "$named" ]; then
    echo "cannot check $1: a name inside it contains a newline" >&2
    exit 2
  fi
  if ! files="$(find "$1" -type f -print)"; then
    echo "could not list every file in $1" >&2
    exit 2
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if [ ! -r "$file" ] || ! kind="$(file -b "$file")"; then
      echo "cannot read $file" >&2
      exit 2
    fi
    case "$kind" in
      Mach-O*) printf '%s\n' "$file" ;;
    esac
  done <<EOF
$(printf '%s\n' "$files" | sort)
EOF
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
    if ! listing="$(cat "$file")"; then
      echo "cannot read listing $file" >&2
      exit 2
    fi
    check "$file" "$listing"
  done
else
  for path in "$@"; do
    if [ -d "$path" ]; then
      binaries="$(macho_files "$path")" || exit 2
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
