#if SWIFTXSTATE_APPLE_SWIFTDATA
import Foundation
import SwiftData
import SwiftXState

/// Persists and restores reactor snapshots using SwiftData.
public struct ReactorPersistenceStore {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Saves the reactor's current snapshot under a stable key (upserts).
    public func save<Context: Codable & Sendable>(
        _ reactor: Reactor<Context>,
        key: String
    ) throws {
        let persisted = try reactor.getPersistedSnapshot()
        let data = try persisted.encodeJSON()

        var descriptor = FetchDescriptor<ReactorSnapshotRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.machineId = persisted.machineId
            existing.snapshotData = data
            existing.updatedAt = .now
        } else {
            modelContext.insert(
                ReactorSnapshotRecord(
                    key: key,
                    machineId: persisted.machineId,
                    snapshotData: data
                )
            )
        }

        try modelContext.save()
    }

    /// Loads a persisted snapshot for the given key.
    public func load(key: String) throws -> PersistedSnapshot? {
        var descriptor = FetchDescriptor<ReactorSnapshotRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            return nil
        }
        return try PersistedSnapshot.decodeJSON(record.snapshotData)
    }

    /// Deletes a persisted snapshot for the given key.
    public func delete(key: String) throws {
        var descriptor = FetchDescriptor<ReactorSnapshotRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            try modelContext.save()
        }
    }

    /// Restores an reactor from a persisted snapshot stored under `key`.
    @discardableResult
    public func restore<Context: Codable & Sendable>(
        _ reactor: Reactor<Context>,
        key: String,
        context: Context? = nil
    ) throws -> Bool {
        guard let persisted = try load(key: key) else {
            return false
        }
        reactor.start(from: persisted, context: context)
        return true
    }

    /// Creates and hydrates an reactor from a persisted snapshot stored under `key`.
    public func createReactor<Context: Codable & Sendable>(
        _ machine: StateMachine<Context>,
        key: String,
        id: String? = nil,
        options: ReactorOptions = ReactorOptions(),
        context: Context? = nil
    ) throws -> Reactor<Context>? {
        guard let persisted = try load(key: key) else {
            return nil
        }
        return SwiftXState.createReactor(
            machine,
            snapshot: persisted,
            id: id,
            options: options,
            context: context
        )
    }
}

/// Convenience for registering SwiftXState persistence models in a `ModelContainer`.
public enum SwiftXStatePersistenceSchema {
    public static let modelTypes: [any PersistentModel.Type] = [
        ReactorSnapshotRecord.self,
        ReplaySessionRecord.self,
    ]
}
#endif
