/// The concrete behavior behind the string names referenced in a `MachineConfig` —
/// the named `actions`, `guards`, `delays`, and `actors` (invoked logic). Pass these to
/// `createMachine(_:implementations:)`, `setup(...)`, or `machine.provide(_:)`.
public struct MachineImplementations<Context: Sendable>: Sendable {
    /// Named actions, keyed by the name used in `.named("…")` / `actionRef`.
    public var actions: [String: @Sendable (ActionArgs<Context>, ParamsBox?) -> Void]
    /// Named guard predicates, keyed by the name used in `.named("…")` / `guardRef`.
    public var guards: [String: @Sendable (ActionArgs<Context>, ParamsBox?) -> Bool]
    /// Named delays (milliseconds), resolved for `after:` transitions referenced by name.
    public var delays: [String: @Sendable (ActionArgs<Context>) -> Int]
    /// Named actor logic for `invoke`/`spawn` (`fromTask`, `fromCallback`, child machines, …).
    public var actors: [String: ActorLogicEntry]

    public init(
        actions: [String: @Sendable (ActionArgs<Context>, ParamsBox?) -> Void] = [:],
        guards: [String: @Sendable (ActionArgs<Context>, ParamsBox?) -> Bool] = [:],
        delays: [String: @Sendable (ActionArgs<Context>) -> Int] = [:],
        actors: [String: ActorLogicEntry] = [:]
    ) {
        self.actions = actions
        self.guards = guards
        self.delays = delays
        self.actors = actors
    }

    /// Backward-compatible factory for legacy non-parameterized implementations.
    public static func legacy(
        actions legacyActions: [String: @Sendable (ActionArgs<Context>) -> Void] = [:],
        guards legacyGuards: [String: @Sendable (ActionArgs<Context>) -> Bool] = [:],
        delays: [String: @Sendable (ActionArgs<Context>) -> Int] = [:],
        actors: [String: ActorLogicEntry] = [:]
    ) -> MachineImplementations<Context> {
        MachineImplementations(
            actions: wrapLegacyActions(legacyActions),
            guards: wrapLegacyGuards(legacyGuards),
            delays: delays,
            actors: actors
        )
    }
}
