#!/usr/bin/env bash
# Reflow-preview A/B on ONE runner (scratch, never merged): arm a = the
# release-line pin, arm b = the feat pin. Each arm builds ghostty-bench from
# its own commit with its own pinned Zig, then the arms run interleaved.
set -euo pipefail
A=510ca45ff8fc1fb03c600dfedae7c6f098402cd8
B=850bb98497044f6632310c303a68974b6289af4b
echo "cpu: $(sysctl -n machdep.cpu.brand_string 2>/dev/null) ncpu: $(sysctl -n hw.ncpu) mem: $(sysctl -n hw.memsize)"
git fetch --no-tags --depth=1 origin "$A" "$B" \
  || git fetch --no-tags origin release/cmux-9ce9b7d0-e2 main
W="${RUNNER_TEMP:-/tmp}/ab"
mkdir -p "$W"
here="$(cd "$(dirname "$0")" && pwd)"
for arm in a b; do
  if [ "$arm" = a ]; then sha=$A; else sha=$B; fi
  git worktree add --detach "$W/$arm" "$sha"
  (
    cd "$W/$arm"
    # shellcheck source=/dev/null
    source next/toolchain.env
    export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
    zig="$(next/install-zig.sh | tail -n 1)"
    echo "arm $arm: commit $sha, zig $("$zig" version), xcode $XCODE_APP"
    grep -n "optimize" src/build/GhosttyBench.zig
    start=$(date +%s)
    "$zig" build -Demit-bench -Dapp-runtime=none -Demit-macos-app=false -Dsentry=false
    echo "arm $arm: build $(( $(date +%s) - start )) s"
    ls -la zig-out/bin/ghostty-bench
    # The toolchain control: the same file, this arm's compiler.
    ( "$zig" build-exe -O ReleaseFast -femit-bin="$W/control-$arm" "$here/control.zig" \
      || "$zig" build-exe -O fast -femit-bin="$W/control-$arm" "$here/control.zig" ) \
      && echo "arm $arm: control built" || echo "arm $arm: control did not build"
  )
done
bench() {
  local arm=$1; shift
  echo "== arm $arm: ghostty-bench $*"
  "$W/$arm/zig-out/bin/ghostty-bench" "$@" 2>&1
}
control() {
  local arm=$1
  [ -x "$W/control-$arm" ] || return 0
  local t0 t1
  t0=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  "$W/control-$arm"
  t1=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  echo "== control arm $arm: $(perl -e "printf '%.1f', ($t1-$t0)*1000") ms"
}
# 200x60 with 2000 styled lines (the bench default). Interleaved; each arm
# runs first in half of the pairs (a b, b a).
for i in 1 2 3 4; do
  bench a +reflow-preview; bench b +reflow-preview
  bench b +reflow-preview; bench a +reflow-preview
done
# 300x80 with 20000 lines.
for i in 1 2; do
  bench a +reflow-preview --terminal-cols=300 --terminal-rows=80 --fill-lines=20000
  bench b +reflow-preview --terminal-cols=300 --terminal-rows=80 --fill-lines=20000
done
for i in 1 2 3; do control a; control b; control b; control a; done
echo "== A/B done"
