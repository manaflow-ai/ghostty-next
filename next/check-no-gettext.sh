#!/usr/bin/env bash
# License gate for GhosttyNextKit: no GNU gettext (libintl, LGPL-2.1) objects
# in any Apple slice. A static LGPL link in an App Store app cannot meet the
# LGPL relink rule, so every slice must build with -Di18n=false.
#
# Usage: next/check-no-gettext.sh <GhosttyNextKit.xcframework>
#
# For each library in Info.plist AvailableLibraries, and for each
# architecture in that library, runs `ar t` and counts members whose names
# match gettext/libintl objects. Fails when a count is not zero, when a
# slice has no archive, or when the xcframework lists no libraries.
set -euo pipefail
x="${1:?usage: check-no-gettext.sh <xcframework>}"
plist="$x/Info.plist"
[ -f "$plist" ] || { echo "::error::no Info.plist in $x"; exit 1; }

pattern='dcigettext|bindtextdom|loadmsgcat|textdomain|libintl|gettext|localealias|l10nflist|plural-exp|finddomain|explodename|intl-compat'
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

libs="$(python3 -c '
import plistlib, sys
info = plistlib.load(open(sys.argv[1], "rb"))
for lib in info.get("AvailableLibraries", []):
    print(lib["LibraryIdentifier"] + "\t" + lib["LibraryPath"])
' "$plist")"
[ -n "$libs" ] || { echo "::error::$plist lists no libraries"; exit 1; }

fail=0
slices=0
while IFS=$'\t' read -r ident path; do
  slices=$((slices + 1))
  archive="$x/$ident/$path"
  if [ ! -f "$archive" ]; then
    echo "::error::slice $ident has no archive at $ident/$path"
    fail=1
    continue
  fi
  archs="$(lipo -archs "$archive")"
  [ -n "$archs" ] || { echo "::error::slice $ident: lipo found no architecture"; fail=1; continue; }
  for arch in $archs; do
    thin="$work/$ident-$arch.a"
    if [ "$(echo "$archs" | wc -w)" -gt 1 ]; then
      lipo -thin "$arch" "$archive" -output "$thin"
    else
      cp "$archive" "$thin"
    fi
    members="$(ar t "$thin")"
    total="$(printf '%s\n' "$members" | grep -c . || true)"
    if [ "$total" -eq 0 ]; then
      echo "::error::slice $ident [$arch]: $path has no members"
      fail=1
      continue
    fi
    count="$(printf '%s\n' "$members" | grep -Eci "$pattern" || true)"
    echo "slice $ident [$arch] $path: members=$total gettext_libintl=$count"
    if [ "$count" -ne 0 ]; then
      printf '%s\n' "$members" | grep -Ei "$pattern" | sed 's/^/  /'
      echo "::error::slice $ident [$arch] links GNU gettext/libintl ($count objects)"
      fail=1
    fi
  done
done <<< "$libs"

if [ "$fail" -ne 0 ]; then
  echo "NO-GETTEXT-FAIL"
  exit 1
fi
echo "NO-GETTEXT-PASS ($slices slices)"
