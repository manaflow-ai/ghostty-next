# ghostty-next

ghostty-next is the Ghostty fork that the cmux iOS app embeds. The iOS app
shows remote terminals only: a cmux-tui session host on a Mac, Mac mini or
Cloud VM owns the PTY and the canonical grid. The app renders, encodes input
and sends it back. The design is in the cmux repository,
`plans/cmux-next/ghostty-next.md`.

The desktop cmux app keeps using `manaflow-ai/ghostty`. The two forks do not
share branches.

## Base

`main` = upstream `ghostty-org/ghostty` `main` merged up to the commit in
`next/UPSTREAM_BASE`, plus the patch stack below. Every patch is one
self-describing commit. To move the base, merge upstream `main` into a sync
branch (`sync/upstream-<date>`), update `next/UPSTREAM_BASE` in the same
branch, and land it with a pull request; CI then publishes a new
GhosttyNextKit. Do not rebase `main`: cmux pins `main` commits (the
`ghostty-next` gitlink in cmux and the commits of published GhosttyNextKit
releases), and a pinned commit must stay an ancestor of `main` or
`git submodule update` breaks for every checkout. When the stack needs a
clean replay, rebase it on a side branch and record the old tip as an
ancestor with `git merge -s ours <old main>` before it lands. Never merge
`manaflow-ai/ghostty` into this repo; port a patch from it as a new commit
that names the source commit.

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
| test: iOS simulator render smoke that requires non-black pixels | `next/ios-render-smoke.sh` (build host, `nx-remote --sim`): one MANUAL_MIRROR surface, 24-bit red fill through `process_output`; requires the renderer layer at the view's size, red pixels in its IOSurface, and a screenshot at least 20% red. |
| renderer: size the iOS layer from ghostty_surface_set_size | On iOS the IOSurfaceLayer is a sublayer of the embedder's view and kept zero bounds, so every frame was skipped (black screen). `set_size` and `set_content_scale` now size it (top-left, points = pixels / scale) on the main thread. |
| formatter: replay the cursor relative to origin margins | libghostty-vt VT replay (cmux-tui session host): the screen cursor CUP is emitted relative to the emitted origin margins and saturates at them instead of using DECSC/DECRC, so replay never overwrites the saved cursor. Upstream already emits the cursor after terminal state (997a2aff2a). Ported from manaflow-ai/ghostty 5543a00ff..533c27ae1c (9e49174be, d6fdb42e1, 6fd6762a9, b1d0adddd, 28b6fc6f4, 2bba4149b, e57ffa985, 9ddb1ab57). |
| formatter: keep trailing and styled blank rows in VT replay | libghostty-vt VT replay: when the cursor is replayed, trailing blank rows are kept (all row breaks but the final one, which is carried to the next page) so the replay target does not scroll; fully styled blank rows are content for styled output; blank cells after a styled cell close the style first. Ported from manaflow-ai/ghostty a3e9304c5d, 3429f20e9f, 9961d09be3, 9d8d40319, 2439e8e7c and 51c8da0ced. |
| test: OSC dynamic color resets follow later C API defaults | Regression test from manaflow-ai/ghostty d6f611a30: after OSC 110/111/112 resets, the terminal and the render state follow C API default changes. The fix itself is upstream (7cd2f65f5); only the test is ported. |
| lib-vt: expose the effective cursor visual state | `GHOSTTY_TERMINAL_DATA_CURSOR_VISUAL_STYLE` (43, `GhosttyTerminalCursorStyle`) and `GHOSTTY_TERMINAL_DATA_CURSOR_BLINKING` (44, `bool`) on the terminal, appended after upstream values. Ported from manaflow-ai/ghostty 9a614e570. |
| lib-vt: expose cursor semantic activity | `GHOSTTY_TERMINAL_DATA_CURSOR_ACTIVITY` (45, `uint64_t`): an opaque token that advances on DECSCUSR, DEC mode 12, alternate screen dispatches, full reset and configured cursor-default changes, so a replay producer sees cursor changes that leave the visual unchanged. Ported from manaflow-ai/ghostty 71ed4f8f6. |
| lib-vt: bounded Kitty graphics state for replay producers | Per-screen image and placement count limits (`GHOSTTY_TERMINAL_OPT/DATA_KITTY_IMAGE_COUNT_LIMIT` 44/46, `..._KITTY_PLACEMENT_COUNT_LIMIT` 45/47), the storage dirty flag (`GHOSTTY_KITTY_GRAPHICS_DATA_DIRTY` 3, `ghostty_kitty_graphics_set` with `GHOSTTY_KITTY_GRAPHICS_OPTION_DIRTY` 0), image enumeration (`ghostty_kitty_graphics_image_iterator_new/_free`, `ghostty_kitty_graphics_image_next`), number aliases (`ghostty_kitty_graphics_image_by_number`, `ghostty_kitty_graphics_image_set_number`) and `GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_INTERNAL` (13). Count eviction reuses upstream byte-limit eviction (allocation-free). API-bearing part of manaflow-ai/ghostty b7feeea5c; its eviction, pin and loader hardening is superseded by upstream. |
| lib-vt: expose Kitty replay image ID cursors | `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_ID_CURSORS` (46, `GhosttyTerminalKittyImageIdCursors*`) and `GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_ID_CURSORS` (48, `GhosttyTerminalKittyImageIdCursorState`): the implicit image-ID cursor of both screens, with the replay cursor of an in-flight chunked implicit upload. Upstream allocates numbered images at the lowest free ID, so only implicit transmissions use the cursor. Ported from manaflow-ai/ghostty a6d4bd584. |
| ci: run the libghostty-vt patch tests | The "Patch unit tests" step also runs `zig build test-lib-vt` with filters for the VT replay formatter, terminal C API and Kitty graphics patch tests. |
| embedded: lock the terminal grid with ghostty_surface_set_grid | The session host owns the grid. `set_grid(cols, rows, generation)` locks it, independent of the view's pixel size; `set_size` then sets only pixels and `ghostty_surface_size` still reports what would fit. The grid is drawn top-left: padding in a larger view, cropped in a smaller one. A MANUAL_MIRROR terminal never reflows (`Terminal.Resize.reflow`). Older generations are refused; `ghostty_surface_grid` returns the grid, the lock and its generation. |
| embedded: restore and encode GHOSTSNP snapshots | `ghostty_surface_restore_snapshot(surface, bytes, len, phase)`: READY swaps in a decoded terminal under the terminal lock (screen generations advance so old pins are stale; the parser resets and replays the snapshot's continuation); HISTORY prepends pages from bytes cut anywhere. `ghostty_surface_encode_snapshot` writes READY, HISTORY or COMPLETE for the phone side of fidelity checks, and `ghostty_surface_snapshot_version` reports the format version. Manual backends track the stream continuation (up to 1 MiB). No replies are emitted. |
| termio: snapshot history refuses malformed records; restored mode 2026 gets its timeout | History bytes come from another machine. A record header claiming more than 64 MiB is refused, and running out of bytes while three complete records are buffered is a malformed record, not one still arriving, so a bad host cannot make the restore buffer without limit. A snapshot cut inside a synchronized update starts the same safety timer the parser starts for `?2026h`. |
| renderer: surface calls never block on a full renderer mailbox | The renderer mailbox was a 64-slot queue whose producers waited when it was full, so `set_size`, `set_focus`, `set_occlusion`, config and font changes on the main thread, and output parsing, waited for a renderer stuck on the GPU. Waiting pushes now spill into an ordered overflow list; latest-wins state messages (size, focus, visibility, cursor blink, display id, presentation health) replace their older copy. `ghostty.h` documents the remaining lock holds. |
| renderer: GPU completions never wait for the app mailbox | `frameCompleted` pushed the renderer health change to the app mailbox with `.forever` before releasing the frame. With the app mailbox full, the completion thread waited for the main thread, which could be in a synchronous draw waiting for that frame. The push is now `.instant`, and the health value is stored only when queued, so a dropped change is sent with the next frame. From the same fix in manaflow-ai/ghostty 90bbff12ad. |
| font: 72 DPI on iOS | `font.face.default_dpi` was 72 only on macOS, so iOS glyphs and padding were 96/72 (1.33x) too large. Apple platforms use 72 points per inch; the content scale gives the pixel density. Ported from manaflow-ai/ghostty 90bbff12ad. |
| renderer: detach the iOS IOSurfaceLayer before freeing the renderer | On iOS the IOSurfaceLayer is a sublayer of the embedder's view and keeps raw pointers to the renderer in its ivars. Renderer deinit now first clears the callback, the contents and the sublayer link on the main queue, only while they still name this renderer, so a later Core Animation pass cannot call freed memory. Ported from manaflow-ai/ghostty adee7043fc and dd726a9a60. |
| renderer: bounded wait when hiding releases the swap chain | `setVisible(false)` released the swap chain on every platform and waited without bound for frames in flight. iOS holds back GPU completions while the app moves to the background, so the render thread (and every waiter on its draw lock) could hang. Hiding now waits at most 100 ms; on timeout the swap chain is kept and released at the next hide or at teardown. |
| test: simulator smoke for set_grid, snapshot restore, 72 DPI and occlusion | `next/ios-render-smoke.sh` runs the app once per check, with output calls on a serial queue: `fill` (red fill, cells at 72 DPI, red again after an occlusion cycle), `grid` (a grid larger than the view crops; a 10x5 grid is red inside its area only; a stale generation is refused), `snapshot` (encode READY and HISTORY, clear, restore: red again). |
| build: flavor ios-v4 | First release with `ghostty_surface_set_grid`, `ghostty_surface_restore_snapshot`, `ghostty_surface_encode_snapshot`, the non-blocking renderer mailbox and the iOS renderer ports. |
| termio: the surface's scrollback limits hold across snapshot restores | A restored terminal took the session host's scrollback limits from the snapshot, so a phone that restores READY only had to re-encode its own state to trim history, dropping scrollback and on-screen Kitty images. A manual backend now applies its config's `scrollback-limit-bytes` and `scrollback-limit-lines` to every restored terminal (HISTORY pages beyond them are dropped from the oldest end) and, through `ghostty_surface_update_config`, to the live terminal (oldest complete pages freed, never the screen or its images). No new C API: the existing config key holds across restores because the restore reads it from the surface config. Exec surfaces keep upstream behavior (limits apply to new surfaces only). |
| test: render smoke restores under a surface scrollback limit | The `snapshot` check sets `scrollback-limit-bytes = 65536` on the surface with `ghostty_surface_update_config` before it restores READY and HISTORY (about 380 KB of history); the restore succeeds and the red fill is back. |
| build: flavor ios-v5 | First release where restored terminals keep the surface's scrollback limits. |
| ci: release labels are never reused and docs-only pushes do not publish | `next/release_plan.py` + tests; plan job gates build and publish (coordinator decision 2026-10-03). |
| lib-vt: Kitty cell offsets do not shrink c/r placements | In libghostty-vt a placement sized by columns/rows keeps its full cell size; X/Y offsets only move it (the size the cmux-tui session host renders, as manaflow-ai/ghostty does). The Ghostty app keeps upstream c5a3c7e2e, where offsets move the near edge inward. |
| lib-vt: report associated text produced by a consumed Alt | libghostty-vt Kitty key encoding keeps the associated text when Alt was consumed to produce it (an Option-generated character), as manaflow-ai/ghostty does. The Ghostty app keeps upstream behavior. Ported from manaflow-ai/ghostty 14d4d041b8 and 7e091b0efb. |
| lib-vt: word selection endpoints stay on wide glyph leads | `ghostty_terminal_select_word` moves an endpoint off a wide-character spacer onto its glyph lead: a word that begins with a wrapped wide glyph starts on the next row, and a word that ends with a wide glyph ends on its lead, as manaflow-ai/ghostty reports them. `Screen.selectWord` (upstream a3e80a685, used by the app) is unchanged. |
| test: VT replay restores pending wrap under origin mode | Regression test: with DECOM and margins, the formatter alone restores the cursor cell and the pending wrap. A consumer must not reprint the cursor cell again. |
| ci: run the round-2 libghostty-vt patch tests | Filters for the cell-offset sizing, consumed-Alt text, word-selection and pending-wrap tests, in both the app (`zig build test`) and libghostty-vt (`zig build test-lib-vt`) runs, so both artifacts are proven. |
| formatter: lib-vt returns from tabstops with a carriage return | Tabstop serialization moves only the column (CHA), so libghostty-vt ends it with CR instead of CUP home. A consumer that writes a selection after its own earlier rows (the cmux-tui segmented replay) no longer has the following rows moved to the top of the screen. The Ghostty app keeps upstream e523cf810. |
| termio: manual surfaces do not assume the shell redraws the prompt | MANUAL and MANUAL_MIRROR terminals start with `shell_redraws_prompt = false`, matching libghostty-vt embedder terminals (see "Behavior that differs from upstream"). EXEC surfaces are unchanged. |
| termio: manual surfaces keep the raw OSC 7 URL | MANUAL and MANUAL_MIRROR store the OSC 7 URL as libghostty-vt does, with no local-host check, and decode the path on read (see "Behavior that differs from upstream"). EXEC is unchanged. |
| Add config load string C API | `ghostty_config_load_string(config, bytes, len, path)`: config lines from memory; `path` names them in diagnostics and resolves relative paths. The cmux-next Mac app loads theme, keybind and padding lines with it. Cherry-picked from manaflow-ai/ghostty f7880c4731. |
| config: c_get returns window-padding-x/-y as ghostty_config_window_padding_s | `ghostty_config_get` fills `{top_left, bottom_right}` points for the padding keys. Cherry-picked from manaflow-ai/ghostty b1a49b6015. |
| embedded: report performed font binding actions to the embedder | `ghostty_surface_set_font_size_action_callback`: one-shot per-surface callback on the GUI thread after increase, decrease, reset or set font size, with previous and current points and adjusted flags (per-tab zoom records). Ported from manaflow-ai/ghostty bc1d15f1b9. |
| embedded: ghostty_surface_grid_metrics | Grid, canonical cursor cell, cell size and padding in points. With a host-locked grid (`set_grid`) the metrics describe the locked grid; an unlocked grid refuses a resize in flight. Ported from manaflow-ai/ghostty aeed68c443; the canonical-cell helper is private to the embedded apprt, so libghostty-vt is unchanged. |
| embedded: bounded selection copy and clear selection | `ghostty_surface_copy_selection_to_clipboard_bounded` (plain text required, HTML only when it fits, selection kept) and `ghostty_surface_clear_selection`. Adapted from manaflow-ai/ghostty 7a5d08b7c3. |
| embedded: keyboard copy mode on upstream selections | `ghostty_surface_select_viewport_cell` (one-cell selection = copy cursor, wide glyphs resolve to the lead), `ghostty_surface_selection_end` (moving end in viewport rows, also above or below it) and `ghostty_surface_select_lines` (widen to whole rows). Movement is upstream `adjust_selection`; scrolling and prompt jumps are upstream binding actions. Replaces the desktop fork's keyboard copy API (about 2,800 lines in `Screen`/`Selection`); this one adds about 160 lines outside the terminal core, so libghostty-vt is unchanged. |

Next in the stack (tracked in the design): presentation callbacks for
frame-exact acknowledgment, Kitty image replay after a snapshot, and a
local scrollback window limit for restored snapshots.

## Behavior that differs from upstream

The next upstream sync must keep these behaviors, or change them in a
reviewed commit that says why.

- OSC 7 working directory in the MANUAL modes: MANUAL and MANUAL_MIRROR
  surfaces store the raw OSC 7 URL (for example
  `file://localhost/Users/dev/project0`), the same form libghostty-vt
  stores. They also skip the local-host check. Upstream keeps only the
  decoded path and drops URLs whose host is not local, and EXEC surfaces
  here keep that. Why: the PTY belongs to a remote session host, so the
  viewer's own host name means nothing there, and the stored form must
  match the host terminal so the pwd keeps its form across snapshot
  restores. Readers that need a path decode it on read (`termio.osc7Path`):
  the pwd action, `Surface.pwd`, relative path opening and the pwd window
  title. Tests: `OSC 7: manual surfaces keep the raw URL and skip the host
  check`, `osc7Path decodes file and kitty-shell-cwd URLs without a host
  check`.
- Prompt redraw in the MANUAL modes: MANUAL and MANUAL_MIRROR surfaces
  create their terminal with `shell_redraws_prompt = false`, the value
  that libghostty-vt's C API (`ghostty_terminal_new`) gives every embedder
  terminal. Upstream surfaces assume the shell redraws its prompt on
  resize, and EXEC surfaces here keep that. Why: the phone mirrors a
  session host's libghostty-vt terminal. With the same value, both
  terminals reflow alike and their GHOSTSNP TERMINAL records match byte
  for byte. A shell can still opt in with OSC 133;A;redraw=1, which both
  parse. Test: `manual: the shell is not assumed to redraw the prompt`.
- Scrollback limits in the MANUAL modes: when the embedder calls
  `ghostty_surface_update_config` on a MANUAL or MANUAL_MIRROR surface,
  `scrollback-limit-bytes` and `scrollback-limit-lines` apply to the live
  terminal at once. Upstream applies these keys to new surfaces only, and
  EXEC surfaces here keep the upstream behavior. Every
  `ghostty_surface_restore_snapshot` (READY and HISTORY) also uses the
  surface config's limits, not the limits in the host's snapshot. Why: the
  iOS app restores host snapshots and must keep its own memory budget.
  Source: PR 8 (`74e97632d40a`), release ios-v5.
  - Trimming frees the oldest complete history pages and keeps the active
    rows and the Kitty images placed on them. So a configured limit can stay
    unmet when the history boundary shares a page with active rows, and the
    line limit always permits at least one standard history page.
    Exception: `scrollback-limit-bytes = 0` erases all history
    (`Terminal.setScrollbackMaxBytes` calls `eraseHistory`), which can remove
    only the history part of a page that it shares with active rows.
  - Test coverage: the Zig restore test covers `scrollback-limit-bytes`
    through a READY restore, a second restore and a live config change; a
    second test covers a live trim that keeps an on-screen Kitty image. No
    test covers `scrollback-limit-lines` on restore yet. The iOS simulator
    smoke checks only that a restore under a byte limit succeeds and draws.

## GhosttyNextKit releases

A push to `main` runs `.github/workflows/next-xcframework.yml` on a remote
macOS runner. It runs `next/build-xcframework.sh`, which pins Zig and Xcode
from `next/toolchain.env`, builds with fixed flags and packages with
`next/package_xcframework.py`. The release tag is
`xcframework-<commit>-<flavor>` (flavor `ios-v2` and later; `ios-v3` is the first with a drawing iOS renderer; `ios-v4` adds `set_grid`, snapshot restore and encode, and non-blocking surface calls; `ios-v5` keeps the surface's scrollback limits across restores) and holds:

- `GhosttyNextKit.xcframework.zip`: deterministic zip. Its sha256 is also the
  SwiftPM checksum.
- `SHA256SUMS`: sha256 of the zip and of the manifest.
- `manifest.json`: commit, upstream base, toolchain versions, flags, and the
  sha256 of each slice library.

A build provenance attestation covers the zip:
`gh attestation verify GhosttyNextKit.xcframework.zip --repo manaflow-ai/ghostty-next`.
A release is never replaced, and a label is never reused: each release is labeled `<flavor>+<12-char sha>` (for example `ios-v5+74e97632d40a`) and tagged `xcframework-<sha>-<flavor>`; the publish job refuses when that tag exists. A push that changes no build input since the newest ancestor release (only `*.md`, `docs/`, issue and discussion templates, LICENSE, CODEOWNERS, VOUCHED) publishes nothing. `next/release_plan.py` decides both; `next/test_release_plan.py` tests them. Pin by URL and sha256, never by label alone. A dispatch with `verify_reproducible` rebuilds
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
