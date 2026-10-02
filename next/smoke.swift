// ghostty-next: proves the xcframework exposes the Swift module
// GhosttyNextKit and that the library initializes.
import GhosttyNextKit

guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
    fatalError("ghostty_init failed")
}
let info = ghostty_info()
print("swift import GhosttyNextKit ok, build_mode=\(info.build_mode.rawValue)")
