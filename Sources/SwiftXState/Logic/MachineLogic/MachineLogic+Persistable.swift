extension MachineLogic: PersistableLogic where Context: ContextPersistable {
    public func persistedSnapshot(
        _ snapshot: MachineSnapshot<Context>,
        children: [String: PersistedChildSnapshot]
    ) throws -> PersistedSnapshot {
        try SwiftXState.getPersistedSnapshot(from: snapshot, children: children)
    }

    public func restoredSnapshot(from persisted: PersistedSnapshot) throws -> MachineSnapshot<Context> {
        try restoreSnapshot(machine: machine, persisted: persisted, context: contextOverride)
    }
}
