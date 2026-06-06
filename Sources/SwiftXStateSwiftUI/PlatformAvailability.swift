#if !SWIFTXSTATE_APPLE_UI
import SwiftXState

/// Indicates whether SwiftUI bindings are available on the current platform.
public enum SwiftXStateSwiftUIPlatformSupport {
    public static let isAvailable = false
    public static let message =
        "SwiftXStateSwiftUI requires macOS, iOS, tvOS, or watchOS with SwiftUI. " +
        "Use SwiftXState directly on Linux and Windows."
}
#endif