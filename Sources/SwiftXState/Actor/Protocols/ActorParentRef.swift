/// Reference from a child actor back to its parent interpreter.
public protocol ActorParentRef: AnyObject, Sendable {
    func enqueueFromChild(_ event: any Eventable) async
    var actorSystem: ActorSystem { get }
    func inspectSpawnedChild(_ child: any ChildActorRef, machineId: String?) async
    func persistedChildSnapshot(for id: String) async -> PersistedChildSnapshot?
}

extension ActorParentRef {
    public func persistedChildSnapshot(for id: String) async -> PersistedChildSnapshot? {
        nil
    }
}
