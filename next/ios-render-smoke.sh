#!/usr/bin/env bash
# ghostty-next iOS render smoke: builds next/ios-smoke into a simulator app,
# runs it in the booted simulator $NX_SIM_UDID, and passes only when
#   1. the app reports RENDER-SMOKE PASS (the renderer layer has the view's
#      size and its IOSurface has non-black, red-filled pixels), and
#   2. a simulator screenshot taken while the app is on screen has at least
#      20% red pixels (the SGR 41 fill the app feeds through process_output).
#
#   next/ios-render-smoke.sh --xcframework <dir>
#   next/ios-render-smoke.sh --release <tag> <sha256>
#
# Never runs on a developer Mac: use the build host (nx-remote --sim).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
: "${NX_SIM_UDID:?set NX_SIM_UDID to a booted simulator}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
case "${1:-}" in
  --xcframework) x="$(cd "$2" && pwd)" ;;
  --release)
    curl -fsSL -o "$work/k.zip" \
      "https://github.com/manaflow-ai/ghostty-next/releases/download/$2/GhosttyNextKit.xcframework.zip"
    got="$(shasum -a 256 "$work/k.zip" | cut -d' ' -f1)"
    echo "sha256 want=$3 got=$got"; [ "$got" = "$3" ]
    (cd "$work" && unzip -q k.zip)
    x="$work/GhosttyNextKit.xcframework" ;;
  *) echo "usage: ios-render-smoke.sh --xcframework <dir> | --release <tag> <sha256>" >&2; exit 2 ;;
esac

slice="$x/ios-arm64-simulator"
lib="$(ls "$slice"/*.a | head -1)"
app="$work/RenderSmoke.app"
mkdir -p "$app"
cp "$here/ios-smoke/Info.plist" "$app/Info.plist"
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator -O \
  -I "$slice/Headers" "$here/ios-smoke/main.swift" "$lib" \
  -framework UIKit -framework IOSurface -framework CoreFoundation -framework CoreGraphics \
  -framework CoreText -framework CoreVideo -framework QuartzCore -framework Metal \
  -framework Foundation -lc++ -o "$app/RenderSmoke"
codesign --force --sign - "$app" >/dev/null
bundle=dev.manaflow.ghosttynext.rendersmoke
xcrun simctl uninstall "$NX_SIM_UDID" "$bundle" >/dev/null 2>&1 || true
xcrun simctl install "$NX_SIM_UDID" "$app"

log="$work/console.log"
xcrun simctl launch --console-pty --terminate-running-process "$NX_SIM_UDID" "$bundle" >"$log" 2>&1 &
launcher=$!
for _ in $(seq 1 120); do
  grep -q 'RENDER-SMOKE-READY\|RENDER-SMOKE FAIL' "$log" && break
  sleep 0.25
done
xcrun simctl io "$NX_SIM_UDID" screenshot "$work/shot.png" >/dev/null 2>&1 || true
wait "$launcher" || true
grep -a 'RENDER-SMOKE' "$log" || { echo "no RENDER-SMOKE line"; cat "$log"; exit 1; }
if [ -n "${NX_ARTIFACTS:-}" ] && [ -f "$work/shot.png" ]; then cp "$work/shot.png" "$NX_ARTIFACTS/render-smoke.png"; fi

sips -s format bmp "$work/shot.png" --out "$work/shot.bmp" >/dev/null
red_pct="$(python3 - "$work/shot.bmp" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
off = struct.unpack_from("<I", d, 10)[0]
w, h = struct.unpack_from("<ii", d, 18)
bpp = struct.unpack_from("<H", d, 28)[0]
bpp_bytes = bpp // 8
row = (w * bpp_bytes + 3) & ~3
h = abs(h)
red = total = 0
for y in range(0, h, 8):
    for x in range(0, w, 8):
        i = off + y * row + x * bpp_bytes
        b, g, r = d[i], d[i + 1], d[i + 2]
        total += 1
        if r > 120 and g < 80 and b < 80:
            red += 1
print(round(100 * red / max(total, 1)))
PY
)"
echo "screenshot red pixels: ${red_pct}%"
grep -aq 'RENDER-SMOKE PASS' "$log" || { echo IOS-RENDER-SMOKE-FAIL; exit 1; }
[ "$red_pct" -ge 20 ] || { echo IOS-RENDER-SMOKE-FAIL; exit 1; }
echo IOS-RENDER-SMOKE-PASS
