#if !SWIFTXSTATE_APPLE_SWIFTDATA
import SwiftXState

/// Indicates whether SwiftData persistence helpers are available on the current platform.
public enum SwiftXStateSwiftDataPlatformSupport {
    public static let isAvailable = false
    public static let message =
        "SwiftXStateSwiftData requires Apple platforms with SwiftData. " +
        "Use Codable persistence via getPersistedSnapshot() on Linux and Windows."
}
#endif