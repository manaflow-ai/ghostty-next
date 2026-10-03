// ghostty-next iOS render smoke. A UIKit app with one GhosttyNextKit
// surface in MANUAL_MIRROR mode, sized like an embedder does it
// (set_content_scale + set_size from layoutSubviews), fed through the
// output functions on a serial queue (process_output, set_grid,
// restore_snapshot), then drawn with ghostty_surface_draw. It reads the
// pixels of the IOSurface the renderer shows, prints one RENDER-SMOKE
// line, stays on screen for a simulator screenshot, and exits 0 (pass)
// or 1 (fail). The first launch argument picks the check:
//
//   fill      a 24-bit red fill covers the view; glyph cells use 72 DPI
//             points; the fill survives an occlusion cycle (the swap
//             chain is released and rebuilt).
//   grid      set_grid larger than the view crops (red everywhere); then
//             a 10x5 grid smaller than the view is red inside the grid
//             area only, and ghostty_surface_size still reports the
//             cells that fit.
//   snapshot  encode the red fill (READY and HISTORY), clear it, then
//             restore the snapshot: the red fill is back.
import GhosttyNextKit
import IOSurface
import UIKit

@MainActor var ghosttyApp: ghostty_app_t?

let mode = CommandLine.arguments.dropFirst().first ?? "fill"

/// The embedder's serial output queue: process_output, set_grid and the
/// snapshot calls run here, never on the main thread.
let outputQueue = DispatchQueue(label: "render-smoke.output")

/// A surface handle passed to the output queue.
struct SurfaceRef: @unchecked Sendable { let raw: ghostty_surface_t }

/// Run `body` on the output queue without blocking the main thread.
func onOutput<T: Sendable>(_ surface: SurfaceRef, _ body: @escaping @Sendable (ghostty_surface_t) -> T) async -> T {
    await withCheckedContinuation { cont in
        outputQueue.async { cont.resume(returning: body(surface.raw)) }
    }
}

func feed(_ surface: ghostty_surface_t, _ text: String) {
    let bytes = Array(text.utf8)
    bytes.withUnsafeBufferPointer { buf in
        buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
            ghostty_surface_process_output(surface, $0, UInt(buf.count))
        }
    }
}

/// Pure red 24-bit background fill (ED 2 uses the background color; a
/// 24-bit color does not depend on the palette), then white text.
let redFill = "\u{1b}[48;2;255;0;0m\u{1b}[2J\u{1b}[H\u{1b}[97mghostty-next render smoke\r\n"

final class SnapshotSink: @unchecked Sendable { var bytes: [UInt8] = [] }

func encode(_ surface: ghostty_surface_t, _ phase: ghostty_surface_snapshot_phase_e) -> [UInt8]? {
    let sink = SnapshotSink()
    let ok = ghostty_surface_encode_snapshot(surface, { userdata, bytes, len in
        let sink = Unmanaged<SnapshotSink>.fromOpaque(userdata!).takeUnretainedValue()
        sink.bytes.append(contentsOf: UnsafeBufferPointer(start: bytes, count: Int(len)))
    }, Unmanaged.passUnretained(sink).toOpaque(), phase)
    return ok ? sink.bytes : nil
}

func restore(_ surface: ghostty_surface_t, _ bytes: [UInt8], _ phase: ghostty_surface_snapshot_phase_e) -> Bool {
    bytes.withUnsafeBufferPointer { ghostty_surface_restore_snapshot(surface, $0.baseAddress, $0.count, phase) }
}

@MainActor
final class TerminalView: UIView {
    var surface: ghostty_surface_t?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard surface == nil, let window, let app = ghosttyApp else { return }
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(self).toOpaque()))
        config.scale_factor = Double(window.screen.scale)
        config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        config.io_write_cb = { _, _, _ in }
        surface = ghostty_surface_new(app, &config)
        guard let surface else { finish(false, "ghostty_surface_new failed") }
        ghostty_surface_set_occlusion(surface, true)
        ghostty_surface_set_focus(surface, true)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let surface, let window else { return }
        let scale = window.screen.scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(bounds.width * scale), UInt32(bounds.height * scale))
    }
}

@MainActor
func finish(_ pass: Bool, _ detail: String) -> Never {
    print("RENDER-SMOKE \(pass ? "PASS" : "FAIL") mode=\(mode) \(detail)")
    fflush(stdout)
    exit(pass ? 0 : 1)
}

/// The pixels of the IOSurface the renderer's layer shows.
@MainActor
struct Pixels {
    let width: Int, height: Int, layerWidthPt: Int, layerHeightPt: Int
    let isRed: (Int, Int) -> Bool
    let nonBlack: (Int, Int) -> Bool

    /// Fraction of a 64x64 sample grid inside `rect` (pixels) that is red.
    func redFraction(x0: Int = 0, y0: Int = 0, x1: Int? = nil, y1: Int? = nil) -> Double {
        let x1 = min(x1 ?? width, width), y1 = min(y1 ?? height, height)
        guard x1 > x0, y1 > y0 else { return 0 }
        var red = 0, total = 0
        for y in stride(from: y0, to: y1, by: max(1, (y1 - y0) / 64)) {
            for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 64)) {
                total += 1
                if isRed(x, y) { red += 1 }
            }
        }
        return Double(red) / Double(max(total, 1))
    }
}

/// Copy the layer's IOSurface into a pixel reader. Nil when the layer or
/// its contents are missing.
@MainActor
func capture(_ view: TerminalView) -> Pixels? {
    guard let host = view.layer.sublayers?.first(where: { String(describing: type(of: $0)) == "IOSurfaceLayer" }),
          let contents = host.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID()
    else { return nil }
    let io = contents as! IOSurfaceRef
    IOSurfaceLock(io, .readOnly, nil)
    defer { IOSurfaceUnlock(io, .readOnly, nil) }
    let w = IOSurfaceGetWidth(io), h = IOSurfaceGetHeight(io), stride = IOSurfaceGetBytesPerRow(io)
    let base = IOSurfaceGetBaseAddress(io).assumingMemoryBound(to: UInt8.self)
    let copy = Array(UnsafeBufferPointer(start: base, count: stride * h))
    func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { // BGRA
        let i = y * stride + x * 4
        return (Int(copy[i + 2]), Int(copy[i + 1]), Int(copy[i]))
    }
    return Pixels(
        width: w, height: h,
        layerWidthPt: Int(host.bounds.width), layerHeightPt: Int(host.bounds.height),
        isRed: { x, y in let (r, g, b) = px(x, y); return r > 200 && g < 60 && b < 60 },
        nonBlack: { x, y in let (r, g, b) = px(x, y); return r + g + b > 30 })
}

/// Tick the app and draw a few frames, as the display link would.
@MainActor
func drawFrames(_ app: ghostty_app_t, _ surface: ghostty_surface_t) async {
    for _ in 0..<6 {
        try? await Task.sleep(for: .milliseconds(100)) // Deterministic waits are fine in a test harness.
        ghostty_app_tick(app)
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
    }
    try? await Task.sleep(for: .milliseconds(300))
}

@MainActor
func runFill(_ app: ghostty_app_t, _ view: TerminalView, _ surface: ghostty_surface_t) async -> (Bool, String) {
    let ref = SurfaceRef(raw: surface)
    await onOutput(ref) { feed($0, redFill) }
    await drawFrames(app, surface)
    guard let first = capture(view) else { return (false, "no IOSurface") }
    let red1 = first.redFraction()

    // Glyph cells at 72 DPI: the default 12 pt font gives a cell about
    // 16 pt tall; 96 DPI would make it about 21 pt.
    let size = ghostty_surface_size(surface)
    let scale = Double(view.window?.screen.scale ?? 1)
    let cellHeightPt = Double(size.cell_height_px) / scale
    let cellWidthPt = Double(size.cell_width_px) / scale

    // Occlusion releases the swap chain; showing the surface rebuilds it.
    ghostty_surface_set_occlusion(surface, false)
    try? await Task.sleep(for: .milliseconds(300))
    ghostty_surface_set_occlusion(surface, true)
    await drawFrames(app, surface)
    guard let second = capture(view) else { return (false, "no IOSurface after occlusion") }
    let red2 = second.redFraction()

    let detail = String(format: "layer=%dx%dpt surface=%dx%dpx red=%.2f red_after_occlusion=%.2f cell=%.1fx%.1fpt",
                        first.layerWidthPt, first.layerHeightPt, first.width, first.height,
                        red1, red2, cellWidthPt, cellHeightPt)
    let pass = first.width > 0 && red1 > 0.8 && red2 > 0.8 && cellHeightPt < 19 && cellWidthPt < 8.5
    return (pass, detail)
}

@MainActor
func runGrid(_ app: ghostty_app_t, _ view: TerminalView, _ surface: ghostty_surface_t) async -> (Bool, String) {
    let ref = SurfaceRef(raw: surface)

    // A grid larger than the view is cropped: red everywhere.
    let bigOK = await onOutput(ref) { s in
        let ok = ghostty_surface_set_grid(s, 500, 300, 1)
        feed(s, redFill)
        return ok
    }
    await drawFrames(app, surface)
    guard let big = capture(view) else { return (false, "no IOSurface (big grid)") }
    let bigRed = big.redFraction()
    let bigGrid = ghostty_surface_grid(surface)

    // A grid smaller than the view: red inside the grid only.
    let smallOK = await onOutput(ref) { s in
        let ok = ghostty_surface_set_grid(s, 10, 5, 2)
        feed(s, redFill)
        return ok
    }
    let staleRefused = await onOutput(ref) { !ghostty_surface_set_grid($0, 40, 20, 1) }
    await drawFrames(app, surface)
    guard let small = capture(view) else { return (false, "no IOSurface (small grid)") }
    let grid = ghostty_surface_grid(surface)
    let size = ghostty_surface_size(surface)
    let gridW = Int(size.cell_width_px) * 10, gridH = Int(size.cell_height_px) * 5
    let cw = Int(size.cell_width_px), ch = Int(size.cell_height_px)
    // Inside: the grid area without its edge cells (the padding offset is
    // a few pixels). Outside: right of the grid and below it.
    let inside = small.redFraction(x0: cw, y0: ch, x1: gridW - cw, y1: gridH - ch)
    let right = small.redFraction(x0: gridW + 2 * cw, y0: 0, x1: small.width, y1: gridH)
    let below = small.redFraction(x0: 0, y0: gridH + 2 * ch, x1: small.width, y1: small.height)

    let detail = String(
        format: "big_grid=%dx%d locked=%d red=%.2f small_grid=%dx%d gen=%llu fits=%dx%d inside_red=%.2f right_red=%.2f below_red=%.2f stale_refused=%d",
        Int(bigGrid.columns), Int(bigGrid.rows), bigGrid.locked ? 1 : 0, bigRed,
        Int(grid.columns), Int(grid.rows), grid.generation, Int(size.columns), Int(size.rows),
        inside, right, below, staleRefused ? 1 : 0)
    let pass = bigOK && smallOK && staleRefused
        && bigGrid.locked && bigGrid.columns == 500 && bigRed > 0.8
        && grid.locked && grid.columns == 10 && grid.rows == 5 && grid.generation == 2
        && size.columns > 10 && size.rows > 5
        && inside > 0.9 && right == 0 && below == 0
    return (pass, detail)
}

@MainActor
func runSnapshot(_ app: ghostty_app_t, _ view: TerminalView, _ surface: ghostty_surface_t) async -> (Bool, String) {
    let ref = SurfaceRef(raw: surface)
    let parts = await onOutput(ref) { s -> ([UInt8]?, [UInt8]?) in
        feed(s, redFill)
        // Scrollback for the HISTORY phase.
        for i in 0..<2000 { feed(s, "line \(i)\r\n") }
        feed(s, redFill)
        return (encode(s, GHOSTTY_SURFACE_SNAPSHOT_READY), encode(s, GHOSTTY_SURFACE_SNAPSHOT_HISTORY))
    }
    guard let ready = parts.0, let history = parts.1 else { return (false, "encode failed") }

    // Clear to the default background: no red left.
    await onOutput(ref) { feed($0, "\u{1b}[0m\u{1b}[2J\u{1b}[3J\u{1b}[H") }
    await drawFrames(app, surface)
    guard let cleared = capture(view) else { return (false, "no IOSurface (cleared)") }
    let clearedRed = cleared.redFraction()

    let restored = await onOutput(ref) { s in
        restore(s, ready, GHOSTTY_SURFACE_SNAPSHOT_READY) && restore(s, history, GHOSTTY_SURFACE_SNAPSHOT_HISTORY)
    }
    await drawFrames(app, surface)
    guard let after = capture(view) else { return (false, "no IOSurface (restored)") }
    let restoredRed = after.redFraction()

    let version = ghostty_surface_snapshot_version()
    let detail = String(format: "version=%d ready=%dB history=%dB restore=%d cleared_red=%.2f restored_red=%.2f",
                        Int(version), ready.count, history.count, restored ? 1 : 0, clearedRed, restoredRed)
    let pass = version >= 1 && restored && clearedRed == 0 && restoredRed > 0.8
    return (pass, detail)
}

@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS,
              let config = ghostty_config_new() else { finish(false, "ghostty_init") }
        ghostty_config_finalize(config)
        var runtime = ghostty_runtime_config_s()
        runtime.wakeup_cb = { _ in }
        runtime.action_cb = { _, _, _ in false }
        runtime.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, _, _, _ in }
        runtime.close_surface_cb = { _, _ in }
        guard let app = ghostty_app_new(&runtime, config) else { finish(false, "ghostty_app_new") }
        ghosttyApp = app
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene, let app = ghosttyApp else { finish(false, "no scene or app") }
        let window = UIWindow(windowScene: windowScene)
        let controller = UIViewController()
        let view = TerminalView(frame: window.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view = view
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window

        Task { @MainActor in
            view.layoutIfNeeded()
            guard let surface = view.surface else { finish(false, "no surface") }
            let (pass, detail): (Bool, String)
            switch mode {
            case "grid": (pass, detail) = await runGrid(app, view, surface)
            case "snapshot": (pass, detail) = await runSnapshot(app, view, surface)
            default: (pass, detail) = await runFill(app, view, surface)
            }
            print("RENDER-SMOKE-READY")
            fflush(stdout)
            // Stay on screen for the simulator screenshot.
            try? await Task.sleep(for: .seconds(4))
            finish(pass, detail)
        }
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
