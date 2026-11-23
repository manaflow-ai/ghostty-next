# Renderer

Guidance for changes in `src/renderer/` (the per-surface renderer thread,
`generic.zig`, the Metal and OpenGL backends, and the display links).
cmux runs many surfaces per process, most of them hidden, so a cost this
code pays per surface is paid hundreds of times.

## Rules

- **Display link state changes only on the main thread.** Never call
  `CVDisplayLinkStart`, `CVDisplayLinkStop` or
  `CVDisplayLinkSetCurrentCGDisplay` from the renderer thread. Go through
  `DisplayLink.zig` (macOS) or `IosDisplayLink.zig` (iOS), which apply the
  requested state on the main thread. Calling CoreVideo from the render
  thread can collide with its own stop and start on a display change and
  hang both threads (see the header of `DisplayLink.zig` and
  https://github.com/ghostty-org/ghostty/discussions/14150).
- **No coalescing delay on the echo path.** A wakeup renders at once
  (`Thread.zig` `wakeupCallback`); vsync paces frames. Do not add a timer
  or batch window between output arriving and the frame update. Batch only
  where it saves syscalls or GPU submissions and adds no wait to the first
  frame after idle.
- **Short terminal-lock hold.** A frame update copies what it needs from
  the terminal under the lock and does the rest (style lookups, cell
  building) after it is released. Do not move work back under the lock.
- **Hidden surfaces cost nothing per output.** An occluded or unrealized
  surface does no cell rebuild, holds no swap chain, and should not be
  woken per output chunk. A change that adds work on that path must say
  what it costs per hidden surface.
- **Name the per-surface cost of any new resource.** A new thread, timer,
  texture, atlas copy or command queue per surface states its bytes or
  threads per surface and why it cannot be shared (a glyph atlas per font
  grid shared by every surface is the intended direction).

## Measuring

- Typing latency: the "parsed to frame contents" segment of cmux
  `scripts/cmux-next/bench-typing.py` is the part this renderer owns. Near one refresh at
  p95 means the display-link wait is the cost; small means look upstream.
- Memory: report bytes per surface (CPU and GPU) for a change that touches
  atlases, swap chains or cached terminal state, before and after, from
  the same harness.
