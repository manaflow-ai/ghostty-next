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
| build: enable blocks when translating Apple SDK headers | iOS 26.5 SDK CoreGraphics headers use blocks. |
| ci: zero archive dates and add a link smoke | `ZERO_AR_DATE=1`; `next/smoke.sh` links every slice and runs macOS (and the simulator when one is given). |
| termio: add the manual backend | Remote IO: no PTY, no subprocess, no read thread. Output comes in through `Termio.processOutput`; writes, focus reports and resizes run on the caller thread. Ported from manaflow-ai/ghostty d631f36cea and 22fa801f88. |
| termio: suppress replies for mirror renderers | Remote IO: the session host answers terminal queries, so a mirror drops parser replies (DA, DSR, CPR, XTVERSION, mode reports, OSC color queries, Kitty graphics and clipboard replies, title and clipboard reads) and size, color scheme and visibility reports. Ported from manaflow-ai/ghostty 581dbf264f. |
| embedded: expose manual and manual-mirror surface IO | Remote IO C API, same names and values as manaflow-ai/ghostty: `ghostty_surface_io_mode_e`, `ghostty_surface_config_s.io_mode`/`io_write_cb`/`io_write_userdata`, `ghostty_io_write_cb`, `ghostty_surface_process_output`. Threading and resize semantics are documented in `ghostty.h`. |
| embedded: add committed text input | `ghostty_surface_text_input`: typed text and IME commits without paste semantics (no bracketed paste, LF to CR), as the iOS app sends them. Ported from manaflow-ai/ghostty 22fa801f88. |
| ci: run the remote IO unit tests | `next-xcframework.yml` runs `zig build test` with filters for the patch tests before the GhosttyKit build. |
| termio: manual backends load only in-band Kitty graphics | Remote output names files, temporary files and shared memory on another machine. Loading them would read or unlink local files and leak which paths exist, so a manual backend uses the direct-only limits at init and on config change. |
| remote IO: leave clear_screen and reset of a mirror to its owner | In MANUAL_MIRROR the clear_screen and reset binding actions return false (not performed) and leave the grid to the owning terminal core. In MANUAL, clear_screen runs on the caller thread so its form feed stays in order with user input. |
| termio: deliver Kitty clipboard writes to mirrors without the reply | OSC 5522 writes now behave like OSC 52 in MANUAL_MIRROR: the surface applies the write, and a `reply` flag on the request suppresses the status packet. `isReplyRequest` is exhaustive. |

Next in the stack (tracked in the design): iOS renderer fixes and snapshot
restore from the session host.

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
on a second runner without caches and compares slice hashes. Known
difference before this check can pass: C objects compiled from Zig packages
embed the per-build global cache path (`~/.cache/zig/b/<hash>`).

Push and pull request events did not start runs when this repository was
created; run the workflow with `gh workflow run next-xcframework.yml --ref
<branch> [-f publish=true]` until they do.

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
