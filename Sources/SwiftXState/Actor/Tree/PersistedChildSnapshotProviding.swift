protocol PersistedChildSnapshotProviding {
    func makePersistedChildSnapshot() async throws -> PersistedChildSnapshot?
}

