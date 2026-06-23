protocol PersistedChildSnapshotProviding {
    func makePersistedChildSnapshot() async throws -> PersistedChildSnapshot?
}

func collectPersistedChildSnapshots(
    from children: [String: any ChildActorRef]
) async throws -> [String: PersistedChildSnapshot] {
    var result: [String: PersistedChildSnapshot] = [:]
    for (id, child) in children {
        guard let provider = child as? any PersistedChildSnapshotProviding else { continue }
        if let snapshot = try await provider.makePersistedChildSnapshot() {
            result[id] = snapshot
        }
    }
    return result
}
