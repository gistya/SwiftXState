import Foundation

/// Configuration for invoking a child actor when entering a state.
public struct InvokeConfig<Context: Sendable>: Sendable {
    public var id: String
    public var src: ActorSource
    public var systemId: String?
    public var input: (@Sendable (ActionArgs<Context>) -> SendableValue?)?
    public var onDone: TransitionInput<Context>?
    public var onError: TransitionInput<Context>?
    public var onSnapshot: TransitionInput<Context>?
    /// Restore behavior for opaque children (task / callback / taskGroup) when hydrating.
    public var opaqueRestorePolicy: OpaqueInvokeRestorePolicy
    /// When `false`, the child runs locally but is not registered with Stately Inspector.
    public var inspectable: Bool

    public var syncSnapshot: Bool { onSnapshot != nil }

    public init(
        id: String,
        src: ActorSource,
        systemId: String? = nil,
        input: (@Sendable (ActionArgs<Context>) -> SendableValue?)? = nil,
        onDone: TransitionInput<Context>? = nil,
        onError: TransitionInput<Context>? = nil,
        onSnapshot: TransitionInput<Context>? = nil,
        opaqueRestorePolicy: OpaqueInvokeRestorePolicy = .restart,
        inspectable: Bool = true
    ) {
        self.id = id
        self.src = src
        self.systemId = systemId
        self.input = input
        self.onDone = onDone
        self.onError = onError
        self.onSnapshot = onSnapshot
        self.opaqueRestorePolicy = opaqueRestorePolicy
        self.inspectable = inspectable
    }
}






/// An action that spawns a child actor from an `ActorSource` (`fromTask`, `fromCallback`, a child
/// machine, or a `.named` registered actor). `input` seeds the child's context; `syncSnapshot`
/// streams the child's snapshots back to the parent. XState's `spawnChild`.
public func spawnChild<Context: Sendable>(
    _ src: ActorSource,
    id: String? = nil,
    systemId: String? = nil,
    input: (@Sendable (ActionArgs<Context>) -> SendableValue?)? = nil,
    syncSnapshot: Bool = false,
    inspectable: Bool = true
) -> ActionRef<Context> {
    .spawn(
        SpawnRef(
            src: src,
            id: id,
            systemId: systemId,
            input: input,
            syncSnapshot: syncSnapshot,
            inspectable: inspectable
        )
    )
}

/// An action that sends an event to this actor's parent. XState's `sendParent`.
public func sendParent<Context: Sendable>(_ event: Event) -> ActionRef<Context> {
    .sendParent(event)
}

/// An action that stops the spawned/invoked child actor with the given id.
public func stopChild<Context: Sendable>(_ id: String) -> ActionRef<Context> {
    .stopChild(.fixed(id))
}

/// Stops a child actor whose id is resolved at runtime.
public func stopChild<Context: Sendable>(
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> String
) -> ActionRef<Context> {
    .stopChild(.expression(expression))
}

/// Stops a child actor. Alias for `stopChild`, matching XState's deprecated `stop` export.
public func stop<Context: Sendable>(_ id: String) -> ActionRef<Context> {
    stopChild(id)
}

/// Stops a child actor whose id is resolved at runtime.
public func stop<Context: Sendable>(
    _ expression: @escaping @Sendable (ActionArgs<Context>) -> String
) -> ActionRef<Context> {
    stopChild(expression)
}
