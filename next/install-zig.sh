#!/usr/bin/env bash
# Install the pinned Zig into $1 (default: $RUNNER_TEMP or /tmp) and verify
# its SHA-256. Prints the zig path on the last line. macOS arm64 only: the
# GhosttyNextKit build needs Xcode, so it never runs on Linux.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=toolchain.env
source "$here/toolchain.env"
[ "$(uname -s)" = Darwin ] || { echo "install-zig.sh: macOS only" >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "install-zig.sh: arm64 only" >&2; exit 1; }
root="${1:-${RUNNER_TEMP:-/tmp}}/zig-$ZIG_VERSION"
name="zig-aarch64-macos-$ZIG_VERSION"
if [ -x "$root/$name/zig" ] && [ "$("$root/$name/zig" version)" = "$ZIG_VERSION" ]; then
  echo "$root/$name/zig"; exit 0
fi
mkdir -p "$root"
tarball="$root/$name.tar.xz"
ok=0
for url in \
  "https://ziglang.org/download/$ZIG_VERSION/$name.tar.xz" \
  "https://zig-mirror.tsimnet.eu/zig/$name.tar.xz" \
  "https://pkg.hexops.org/zig/$name.tar.xz"; do
  if curl --fail --location --silent --show-error --retry 3 --connect-timeout 20 --max-time 600 -o "$tarball" "$url"; then
    if printf '%s  %s\n' "$ZIG_AARCH64_MACOS_SHA256" "$tarball" | shasum -a 256 -c - >/dev/null; then
      ok=1; break
    fi
    echo "checksum mismatch from $url" >&2
  fi
done
[ "$ok" = 1 ] || { echo "install-zig.sh: no verified Zig $ZIG_VERSION download" >&2; exit 1; }
tar -xf "$tarball" -C "$root"
rm -f "$tarball"
echo "$root/$name/zig"
