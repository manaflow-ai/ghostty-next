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
publish a new GhosttyNextKit. Never merge `manaflow-ai/ghostty` into this repo;
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
| embedded: tighten manual surface input and output | `process_output` is a no-op for exec surfaces and parses in 64 KiB slices with one terminal lock hold each. New surfaces do not inherit a manual surface working directory. A mirror sends only an explicit `initial_input`, not the global `input` config. `text_input` turns CRLF into one CR. |
| ghostty.h: manual IO threading contract | Every surface call except `process_output` on the main thread, `process_output` on one serial queue, no synchronous wait on that queue from main or `io_write_cb`, `process_output` stopped before `ghostty_surface_free`. Lists which thread calls `io_write_cb` for each kind of write. |
| test: manual IO byte corpus and queueMessage tests | Feeds every query class through `Stream.nextSlice` with suppression on and off, and drives `Termio.queueMessage` on a manual backend (locked and unlocked writes, `write_alloc` free, LNM, focus with mode 1004, resize, `processOutput`, Kitty limits). The none runtime gets a no-op `wakeup` so the tests can use a real app mailbox. |

Differences from manaflow-ai/ghostty in the remote IO mode: MANUAL_MIRROR
sends user focus reports (mode 1004) to `io_write_cb`; the desktop fork
drops them. `io_write_cb` gets user input synchronously on the caller
thread. New tab and split surfaces do not inherit the IO fields.
| build: name the ios xcframework and module GhosttyNextKit | Avoids a module collision with the desktop GhosttyKit in shared workspaces; flavor `ios-v2`; the smoke test also compiles `import GhosttyNextKit` in Swift. |
| test: iOS simulator render smoke that requires non-black pixels | `next/ios-render-smoke.sh` (build host, `nx-remote --sim`): one MANUAL_MIRROR surface, red fill through `process_output`; requires the renderer layer at the view's size, red pixels in its IOSurface, and a screenshot at least 20% red. |
| renderer: size the iOS layer from ghostty_surface_set_size | On iOS the IOSurfaceLayer is a sublayer of the embedder's view and kept zero bounds, so every frame was skipped (black screen). `set_size` and `set_content_scale` now size it (top-left, points = pixels / scale) on the main thread. |

Next in the stack (tracked in the design): iOS renderer fixes and snapshot
restore from the session host.

## GhosttyNextKit releases

A push to `main` runs `.github/workflows/next-xcframework.yml` on a remote
macOS runner. It runs `next/build-xcframework.sh`, which pins Zig and Xcode
from `next/toolchain.env`, builds with fixed flags and packages with
`next/package_xcframework.py`. The release tag is
`xcframework-<commit>-<flavor>` (flavor `ios-v2` and later) and holds:

- `GhosttyNextKit.xcframework.zip`: deterministic zip. Its sha256 is also the
  SwiftPM checksum.
- `SHA256SUMS`: sha256 of the zip and of the manifest.
- `manifest.json`: commit, upstream base, toolchain versions, flags, and the
  sha256 of each slice library.

A build provenance attestation covers the zip:
`gh attestation verify GhosttyNextKit.xcframework.zip --repo manaflow-ai/ghostty-next`.
A release is never replaced. A dispatch with `verify_reproducible` rebuilds
on a second runner without caches and compares slice hashes. Known
difference before this check can pass: C objects compiled from Zig packages
embed the per-build global cache path (`~/.cache/zig/b/<hash>`).

The xcframework and its Swift module are named `GhosttyNextKit` (only
for `-Dxcframework-target=ios`; the other targets keep upstream's
`GhosttyKit`), so the iOS app and the desktop app can share one Xcode
workspace without a module collision. Releases with flavor `ios-v1` use the
old name `GhosttyKit`; do not pin them.

Builds never run on a developer Mac.

## Pinning from the iOS app

The app pins one release in its package manifest:

```swift
.binaryTarget(
    name: "GhosttyNextKit",
    url: "https://github.com/manaflow-ai/ghostty-next/releases/download/xcframework-<commit>-<flavor>/GhosttyNextKit.xcframework.zip",
    checksum: "<sha256 from SHA256SUMS>"
)
```

SwiftPM downloads the public asset without credentials and refuses a
checksum mismatch. A pin change is one reviewed commit in the app that
changes both values. Swift code imports the module with
`import GhosttyNextKit`; the C API names (`ghostty_*`) are unchanged.
