#if SWIFTXSTATE_APPLE_SWIFTDATA
import Foundation
import SwiftData

/// SwiftData model storing a recorded replay session blob.
@Model
public final class ReplaySessionRecord {
    @Attribute(.unique) public var key: String
    public var rootId: String
    public var machineId: String?
    public var sessionData: Data
    public var stepCount: Int
    public var updatedAt: Date

    public init(
        key: String,
        rootId: String,
        machineId: String?,
        sessionData: Data,
        stepCount: Int,
        updatedAt: Date = .now
    ) {
        self.key = key
        self.rootId = rootId
        self.machineId = machineId
        self.sessionData = sessionData
        self.stepCount = stepCount
        self.updatedAt = updatedAt
    }
}
#endif