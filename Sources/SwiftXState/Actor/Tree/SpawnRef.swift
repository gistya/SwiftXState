public struct SpawnRef<Context: Sendable>: Sendable {
    public var src: ActorSource
    public var id: String?
    public var systemId: String?
    public var input: (@Sendable (ActionArgs<Context>) -> SendableValue?)?
    public var syncSnapshot: Bool
    /// When `false`, the child runs locally but will not give output for visibility in Inspector.
    public var inspectable: Bool
    public var opaqueRestorePolicy: OpaqueInvokeRestorePolicy

    public init(
        src: ActorSource,
        id: String? = nil,
        systemId: String? = nil,
        input: (@Sendable (ActionArgs<Context>) -> SendableValue?)? = nil,
        syncSnapshot: Bool = false,
        inspectable: Bool = true,
        opaqueRestorePolicy: OpaqueInvokeRestorePolicy = .restart
    ) {
        self.src = src
        self.id = id
        self.systemId = systemId
        self.input = input
        self.syncSnapshot = syncSnapshot
        self.inspectable = inspectable
        self.opaqueRestorePolicy = opaqueRestorePolicy
    }
}
