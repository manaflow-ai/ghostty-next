#!/usr/bin/env bash
# GhosttyNextKit link-and-run smoke for ghostty-next.
#
#   next/smoke.sh --xcframework <dir>          use a local build
#   next/smoke.sh --release <tag> <sha256>     download, verify, then test
#
# Links next/smoke.c (ghostty_init, ghostty_info, config) against every
# slice, runs the macOS binary, and runs the simulator binary in the
# simulator $NX_SIM_UDID when it is set. Prints SMOKE-PASS on success.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
case "${1:-}" in
  --xcframework) x="$(cd "$2" && pwd)" ;;
  --release)
    url="https://github.com/manaflow-ai/ghostty-next/releases/download/$2/GhosttyNextKit.xcframework.zip"
    curl -fsSL -o "$work/k.zip" "$url"
    got="$(shasum -a 256 "$work/k.zip" | cut -d' ' -f1)"
    echo "sha256 want=$3 got=$got"; [ "$got" = "$3" ]
    (cd "$work" && unzip -q k.zip)
    x="$work/GhosttyNextKit.xcframework" ;;
  *) echo "usage: smoke.sh --xcframework <dir> | --release <tag> <sha256>" >&2; exit 2 ;;
esac
frameworks=(-framework CoreFoundation -framework CoreGraphics -framework CoreText
  -framework CoreVideo -framework QuartzCore -framework IOSurface -framework Metal
  -framework Foundation -lc++)
link() { # sdk slice target out extra...
  local sdk="$1" slice="$2" target="$3" out="$4"; shift 4
  local lib; lib="$(ls "$x/$slice"/*.a | head -1)"
  xcrun --sdk "$sdk" clang -target "$target" -I "$x/$slice/Headers" "$here/smoke.c" \
    "$lib" "${frameworks[@]}" "$@" -o "$out"
  echo "linked $slice"
}
link macosx macos-arm64 arm64-apple-macos13 "$work/smoke-macos" -framework AppKit -framework Carbon
"$work/smoke-macos"
# Swift: `import GhosttyNextKit` through the xcframework's module map.
swift_link() { # sdk slice target out extra...
  local sdk="$1" slice="$2" target="$3" out="$4"; shift 4
  local lib; lib="$(ls "$x/$slice"/*.a | head -1)"
  xcrun --sdk "$sdk" swiftc -target "$target" -I "$x/$slice/Headers" "$here/smoke.swift" \
    "$lib" "${frameworks[@]}" "$@" -o "$out"
  echo "swift linked $slice"
}
swift_link macosx macos-arm64 arm64-apple-macos13 "$work/smoke-swift-macos" -framework AppKit -framework Carbon
"$work/smoke-swift-macos"
swift_link iphonesimulator ios-arm64-simulator arm64-apple-ios17.0-simulator "$work/smoke-swift-sim" -framework UIKit
link iphonesimulator ios-arm64-simulator arm64-apple-ios17.0-simulator "$work/smoke-sim" -framework UIKit
link iphoneos ios-arm64 arm64-apple-ios17.0 "$work/smoke-ios" -framework UIKit
if [ -n "${NX_SIM_UDID:-}" ]; then
  xcrun simctl spawn "$NX_SIM_UDID" "$work/smoke-sim"
  xcrun simctl spawn "$NX_SIM_UDID" "$work/smoke-swift-sim"
fi
echo SMOKE-PASS
