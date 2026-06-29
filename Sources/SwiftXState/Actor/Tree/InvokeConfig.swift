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
