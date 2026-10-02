/// Target for xcframework builds. This is a separate file so that
/// our runtime code doesn't need to import build code.
pub const Target = enum {
    native,
    universal,

    /// ghostty-next: iOS device, iOS simulator and a native macOS slice.
    /// The macOS slice lets host-side Swift package tests link the same
    /// library; apps ship only the iOS slices.
    ios,
};
