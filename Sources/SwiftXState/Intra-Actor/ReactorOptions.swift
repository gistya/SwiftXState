/// Options for creating an reactor — clock, system id, input, and inspection wiring.
public struct ReactorOptions: Sendable {
    /// Clock used for `after:` delays and delayed `raise`/`sendTo` (override in tests).
    public var clock: any Clock
    /// Stable id for this reactor within its reactor system (for `sendTo`/`stateIn` references).
    public var systemId: String?
    /// Input passed to the machine's `contextFromInput` to build the initial context.
    public var input: SendableValue?
    /// Sink for this reactor's inspection events — plug in `InspectorStore.observe()` or a transport.
    public var inspect: (@Sendable (InspectionEvent) -> Void)?
    /// When `false`, this reactor does not emit inspection events (Stately graph / sequence).
    public var inspectable: Bool

    public init(
        clock: any Clock = DefaultClock(),
        systemId: String? = nil,
        input: SendableValue? = nil,
        inspect: (@Sendable (InspectionEvent) -> Void)? = nil,
        inspectable: Bool = true
    ) {
        self.clock = clock
        self.systemId = systemId
        self.input = input
        self.inspect = inspect
        self.inspectable = inspectable
    }
}
