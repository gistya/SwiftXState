func collectPersistedChildSnapshots(
    from children: [String: any ChildActorRepresentable]
) async throws -> [String: PersistedChildSnapshot] {
    var result: [String: PersistedChildSnapshot] = [:]
    for (id, child) in children {
        if let snapshot = try await child.makePersistedChildSnapshot() {
            result[id] = snapshot
        }
    }
    return result
}
