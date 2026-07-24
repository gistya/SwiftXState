/// Reference from a child actor back to its parent interpreter.
public protocol ParentActorRepresentable: AnyObject, Sendable {
    func enqueueFromChild(_ event: any Eventable) async
    var actorSystem: ActorSystem { get }
    var sessionId: String { get }
    func inspectSpawnedChild(_ child: any ChildActorRepresentable, machineId: String?) async
    func persistedChildSnapshot(for id: String) async -> PersistedChildSnapshot?
}

extension ParentActorRepresentable {
    public func persistedChildSnapshot(for id: String) async -> PersistedChildSnapshot? {
        nil
    }
}
