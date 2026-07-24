/// Options for creating an actor — clock, system id, input, and inspection wiring.
public struct ActorOptions: Sendable {
    /// Clock used for `after:` delays and delayed `raise`/`sendTo` (override in tests).
    public var clock: ClockHandle
    /// Stable id for this actor within its actor system (for `sendTo`/`stateIn` references).
    public var systemId: String?
    /// Input passed to the machine's `contextFromInput` to build the initial context.
    public var input: SendableValue?
    /// Sink for this actor's inspection events — plug in `InspectorStore.observe()` or a transport.
    public var inspect: (@Sendable (InspectionEvent) -> Void)?
    /// When `false`, this actor does not emit inspection events (Stately graph / sequence).
    public var inspectable: Bool
    /// When `true`, this actor runs on the `MainActor`'s serial executor instead of its own default
    /// (background) executor. This eliminates the thread hop for `send`/`snapshot` calls made *from*
    /// the main actor — useful for latency-sensitive UI — at the cost of running the actor's work on
    /// the main thread. Has no effect on platforms without `Darwin` (the override is Apple-only).
    public var useMainExecutor: Bool
    /// When `false`, the engine does **not** retain an intermediate snapshot for every microstep of a
    /// run-to-completion step — it keeps only the final macrostep snapshot. A run with many eventless
    /// (`always`) / `raise` microsteps otherwise holds one `MachineSnapshot` (and, for a value-typed
    /// `Context`, one distinct context copy) per microstep — O(microsteps × context) per event. Turn
    /// this off for large-`Context` / high-microstep workloads (e.g. simulation reducers).
    ///
    /// **Only takes effect when `inspectable` is `false`.** With `inspectable: true` the microstep
    /// snapshots are always retained, because inspection (Stately microstep/sequence views) is
    /// meaningless without them.
    public var snapshotMicrosteps: Bool

    /// Generic in the clock so `ActorOptions(clock: SimulatedClock())` still compiles unchanged —
    /// the concrete type is erased into ``ClockHandle`` here rather than stored as an existential.
    public init<C: Clock>(
        clock: C = DefaultClock(),
        systemId: String? = nil,
        input: SendableValue? = nil,
        inspect: (@Sendable (InspectionEvent) -> Void)? = nil,
        inspectable: Bool = true,
        useMainExecutor: Bool = false,
        snapshotMicrosteps: Bool = true
    ) {
        self.clock = ClockHandle(clock)
        self.systemId = systemId
        self.input = input
        self.inspect = inspect
        self.inspectable = inspectable
        self.useMainExecutor = useMainExecutor
        self.snapshotMicrosteps = snapshotMicrosteps
    }
}
