#if SWIFTXSTATE_APPLE_SWIFTDATA
import Foundation
import SwiftData

/// SwiftData model storing a persisted actor snapshot blob.
@Model
public final class ActorSnapshotRecord {
    @Attribute(.unique) public var key: String
    public var machineId: String
    public var snapshotData: [UInt8]
    public var updatedAt: Date

    public init(
        key: String,
        machineId: String,
        snapshotData: [UInt8],
        updatedAt: Date = .now
    ) {
        self.key = key
        self.machineId = machineId
        self.snapshotData = snapshotData
        self.updatedAt = updatedAt
    }
}
#endif
