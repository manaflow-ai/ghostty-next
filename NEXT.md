# ghostty-next

ghostty-next is the Ghostty fork that the cmux iOS app embeds. The iOS app
shows remote terminals only: a cmux-tui session host on a Mac, Mac mini or
Cloud VM owns the PTY and the canonical grid. The app renders, encodes input
and sends it back. The design is in the cmux repository,
`plans/cmux-next/ghostty-next.md`.

The desktop cmux app keeps using `manaflow-ai/ghostty`. The two forks do not
share branches.

## Base

`main` = upstream `ghostty-org/ghostty` `main` at the commit in
`next/UPSTREAM_BASE`, plus the patch stack below. Every patch is one
self-describing commit. To move the base, rebase the stack onto a newer
upstream commit, update `next/UPSTREAM_BASE` in the same push, and let CI
publish a new GhosttyKit. Never merge `manaflow-ai/ghostty` into this repo;
port a patch from it as a new commit that names the source commit.

Never push to, or open a pull request against, `ghostty-org/ghostty`. In a
local clone, keep the upstream remote fetch-only:
`git remote set-url --push upstream DISABLED-never-push-upstream`.

## Patch stack

| Commit subject | Why |
| --- | --- |
| build: restore iOS slices in GhosttyKit.xcframework | Upstream stopped building the full library for iOS (7a171895dd); this repo needs it. |
| build: add the ios xcframework target | `-Dxcframework-target=ios`: iOS device, iOS simulator and a native macOS slice for host tests. |
| ci: ghostty-next GhosttyKit pipeline | Replaces the upstream workflows with `next-xcframework.yml`. |

Next in the stack (tracked in the design): the remote IO mode (renderer and
input encoder over an embedder-owned byte stream, no local PTY, no parser
replies), iOS renderer fixes, and snapshot restore from the session host.

## GhosttyKit releases

A push to `main` runs `.github/workflows/next-xcframework.yml` on a remote
macOS runner. It runs `next/build-xcframework.sh`, which pins Zig and Xcode
from `next/toolchain.env`, builds with fixed flags and packages with
`next/package_xcframework.py`. The release tag is
`xcframework-<commit>-<flavor>` and holds:

- `GhosttyKit.xcframework.zip`: deterministic zip. Its sha256 is also the
  SwiftPM checksum.
- `SHA256SUMS`: sha256 of the zip and of the manifest.
- `manifest.json`: commit, upstream base, toolchain versions, flags, and the
  sha256 of each slice library.

A build provenance attestation covers the zip:
`gh attestation verify GhosttyKit.xcframework.zip --repo manaflow-ai/ghostty-next`.
A release is never replaced. A dispatch with `verify_reproducible` rebuilds
on a second runner without caches and compares slice hashes.

Builds never run on a developer Mac.

## Pinning from the iOS app

The app pins one release in its package manifest:

```swift
.binaryTarget(
    name: "GhosttyKit",
    url: "https://github.com/manaflow-ai/ghostty-next/releases/download/xcframework-<commit>-<flavor>/GhosttyKit.xcframework.zip",
    checksum: "<sha256 from SHA256SUMS>"
)
```

SwiftPM downloads the public asset without credentials and refuses a
checksum mismatch. A pin change is one reviewed commit in the app that
changes both values.
