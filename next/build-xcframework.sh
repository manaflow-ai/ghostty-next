#!/usr/bin/env bash
# Reproducible GhosttyKit build for ghostty-next.
#
# Usage: next/build-xcframework.sh <out-dir>
# Needs: macOS arm64, the Xcode in next/toolchain.env with the iOS SDK and the
# Metal toolchain. Runs in CI (Blacksmith macOS) or on a fleet Mac, never on a
# developer Mac. Output: <out-dir>/GhosttyKit.xcframework.zip, SHA256SUMS and
# manifest.json (see next/package_xcframework.py).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
out="${1:?usage: build-xcframework.sh <out-dir>}"
# shellcheck source=toolchain.env
source "$here/toolchain.env"

if [ ! -d "$XCODE_APP/Contents/Developer" ]; then
  echo "pinned Xcode missing: $XCODE_APP; installed:" >&2
  ls -d /Applications/Xcode*.app >&2 || true
  exit 1
fi
export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
xcrun --sdk iphonesimulator --show-sdk-version
if ! xcrun --sdk iphoneos metal -v >/dev/null 2>&1; then
  xcodebuild -downloadComponent MetalToolchain
  xcrun --sdk iphoneos metal -v >/dev/null 2>&1
fi

zig="$("$here/install-zig.sh" | tail -n 1)"
export PATH="$(dirname "$zig"):$PATH"   # build.zig runs `zig env`
[ "$(zig version)" = "$ZIG_VERSION" ]

# Same source tree, same flags, same toolchain => same libraries. The flags
# below are part of the flavor; change GHOSTTYKIT_FLAVOR when they change.
flags=(
  -Demit-xcframework=true
  -Demit-macos-app=false
  -Dxcframework-target=ios
  -Doptimize=ReleaseFast
  -Dsentry=false
  -Di18n=false
)
# Archive members carry no timestamps, so equal inputs give equal archives.
export ZERO_AR_DATE=1
cd "$repo"
rm -rf macos/GhosttyKit.xcframework
zig build "${flags[@]}" --summary failures

mkdir -p "$out"
python3 "$here/package_xcframework.py" \
  --xcframework macos/GhosttyKit.xcframework \
  --out "$out" \
  --flavor "$GHOSTTYKIT_FLAVOR" \
  --zig-version "$ZIG_VERSION" \
  --zig-sha256 "$ZIG_AARCH64_MACOS_SHA256" \
  --flags "${flags[*]}"
