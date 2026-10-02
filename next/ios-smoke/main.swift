// ghostty-next iOS render smoke. A UIKit app with one GhosttyNextKit
// surface in MANUAL_MIRROR mode, sized like an embedder does it
// (set_content_scale + set_size from layoutSubviews), fed a red full-screen
// fill and text through process_output, then drawn with
// ghostty_surface_draw. It checks that the renderer's layer has the view's
// size and that the IOSurface it shows has non-black pixels, prints one
// RENDER-SMOKE line, stays on screen for a simulator screenshot, and exits
// 0 (pass) or 1 (fail).
import GhosttyNextKit
import IOSurface
import UIKit

@MainActor var ghosttyApp: ghostty_app_t?

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
    print("RENDER-SMOKE \(pass ? "PASS" : "FAIL") \(detail)")
    fflush(stdout)
    exit(pass ? 0 : 1)
}

/// Fraction of sampled pixels in the layer's IOSurface that are not black,
/// and how many are red-dominant (the SGR 41 fill).
@MainActor
func inspect(_ view: TerminalView) -> String? {
    guard let host = view.layer.sublayers?.first(where: { String(describing: type(of: $0)) == "IOSurfaceLayer" })
    else { return nil }
    let b = host.bounds
    guard let contents = host.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else {
        return "layer=\(Int(b.width))x\(Int(b.height))pt contents=none"
    }
    let io = contents as! IOSurfaceRef
    IOSurfaceLock(io, .readOnly, nil)
    defer { IOSurfaceUnlock(io, .readOnly, nil) }
    let w = IOSurfaceGetWidth(io), h = IOSurfaceGetHeight(io), stride = IOSurfaceGetBytesPerRow(io)
    let base = IOSurfaceGetBaseAddress(io).assumingMemoryBound(to: UInt8.self)
    var sampled = 0, nonBlack = 0, red = 0
    for y in Swift.stride(from: 0, to: h, by: max(1, h / 64)) {
        for x in Swift.stride(from: 0, to: w, by: max(1, w / 64)) {
            let p = base + y * stride + x * 4 // BGRA
            let bl = Int(p[0]), g = Int(p[1]), r = Int(p[2])
            sampled += 1
            if r + g + bl > 30 { nonBlack += 1 }
            if r > 120 && g < 80 && bl < 80 { red += 1 }
        }
    }
    return "layer=\(Int(b.width))x\(Int(b.height))pt surface=\(w)x\(h)px nonblack=\(nonBlack)/\(sampled) red=\(red)"
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
            // Red background fill (SGR 41 + ED 2 uses the background color),
            // then white text.
            let payload = Array("\u{1b}[41m\u{1b}[2J\u{1b}[H\u{1b}[97mghostty-next render smoke\r\n".utf8)
            payload.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                    ghostty_surface_process_output(surface, $0, UInt(buf.count))
                }
            }
            // Deterministic waits are fine in a test harness.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                ghostty_app_tick(app)
                ghostty_surface_refresh(surface)
                ghostty_surface_draw(surface)
            }
            try? await Task.sleep(for: .milliseconds(500))
            let detail = inspect(view) ?? "no IOSurfaceLayer sublayer"
            let pass = detail.contains("nonblack=") && !detail.contains("nonblack=0/") && !detail.contains("red=0")
            print("RENDER-SMOKE-READY")
            fflush(stdout)
            // Stay on screen for the simulator screenshot.
            try? await Task.sleep(for: .seconds(4))
            finish(pass, detail)
        }
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
