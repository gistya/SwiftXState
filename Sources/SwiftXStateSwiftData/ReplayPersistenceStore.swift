#if SWIFTXSTATE_APPLE_SWIFTDATA
import Foundation
import SwiftData
import SwiftXState

public enum ReplayPersistenceError: Error, Equatable, LocalizedError {
    case noRecordedSession

    public var errorDescription: String? {
        switch self {
        case .noRecordedSession:
            return "InspectionRecorder has no recorded session to persist"
        }
    }
}

/// Persists and loads recorded replay sessions using SwiftData.
public struct ReplayPersistenceStore {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Saves a replay session under a stable key (upserts).
    public func save(_ session: ReplaySession, key: String) throws {
        let data = try session.encodeJSON()

        var descriptor = FetchDescriptor<ReplaySessionRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.rootId = session.rootId
            existing.machineId = session.machineId
            existing.sessionData = data
            existing.stepCount = session.steps.count
            existing.updatedAt = .now
        } else {
            modelContext.insert(
                ReplaySessionRecord(
                    key: key,
                    rootId: session.rootId,
                    machineId: session.machineId,
                    sessionData: data,
                    stepCount: session.steps.count
                )
            )
        }

        try modelContext.save()
    }

    /// Saves the recorder's current session, if any.
    public func save(_ recorder: InspectionRecorder, key: String) throws {
        guard let session = recorder.session() else {
            throw ReplayPersistenceError.noRecordedSession
        }
        try save(session, key: key)
    }

    /// Loads a replay session for the given key.
    public func load(key: String) throws -> ReplaySession? {
        var descriptor = FetchDescriptor<ReplaySessionRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            return nil
        }
        return try ReplaySession.decodeJSON(record.sessionData)
    }

    /// Deletes a replay session for the given key.
    public func delete(key: String) throws {
        var descriptor = FetchDescriptor<ReplaySessionRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            try modelContext.save()
        }
    }
}
#endif