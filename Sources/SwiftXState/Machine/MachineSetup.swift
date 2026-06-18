import Foundation

/// Builder for creating type-safe state machines with predefined actions and guards.
/// Mirrors XState's `setup().createMachine()` API.
public struct MachineSetup<Context: Sendable> {
    /// Named actions referenced by `.named("…")` in the config.
    public var actions: [String: @Sendable (ActionArgs<Context>, ParamsBox?) -> Void]
    /// Named guard predicates referenced by `.named("…")` in the config.
    public var guards: [String: @Sendable (ActionArgs<Context>, ParamsBox?) -> Bool]
    /// Named delays (ms) for `after:` transitions referenced by name.
    public var delays: [String: @Sendable (ActionArgs<Context>) -> Int]
    /// Named reactor logic for `invoke`/`spawn`.
    public var reactors: [String: ReactorLogicEntry]

    public init(
        actions: [String: @Sendable (ActionArgs<Context>, ParamsBox?) -> Void] = [:],
        guards: [String: @Sendable (ActionArgs<Context>, ParamsBox?) -> Bool] = [:],
        delays: [String: @Sendable (ActionArgs<Context>) -> Int] = [:],
        reactors: [String: ReactorLogicEntry] = [:]
    ) {
        self.actions = actions
        self.guards = guards
        self.delays = delays
        self.reactors = reactors
    }

    /// Legacy dictionary initializer (no per-invocation params).
    public init(
        actions legacyActions: [String: @Sendable (ActionArgs<Context>) -> Void] = [:],
        guards legacyGuards: [String: @Sendable (ActionArgs<Context>) -> Bool] = [:],
        delays: [String: @Sendable (ActionArgs<Context>) -> Int] = [:],
        reactors: [String: ReactorLogicEntry] = [:]
    ) {
        self.actions = wrapLegacyActions(legacyActions)
        self.guards = wrapLegacyGuards(legacyGuards)
        self.delays = delays
        self.reactors = reactors
    }

    /// Registers a typed guard spec with compile-time params.
    public func registerGuard<G: GuardSpec>(
        _ spec: G.Type,
        _ body: @escaping @Sendable (ActionArgs<Context>, G.Params) -> Bool
    ) -> MachineSetup<Context> {
        var copy = self
        installGuard(spec, body: body, into: &copy.guards)
        return copy
    }

    /// Registers a typed action spec with compile-time params.
    public func registerAction<A: ActionSpec>(
        _ spec: A.Type,
        _ body: @escaping @Sendable (ActionArgs<Context>, A.Params) -> Void
    ) -> MachineSetup<Context> {
        var copy = self
        installAction(spec, body: body, into: &copy.actions)
        return copy
    }

    /// Creates a state machine with the setup's implementations.
    public func createMachine(_ config: MachineConfig<Context>) -> StateMachine<Context> {
        SwiftXState.createMachine(
            config,
            implementations: MachineImplementations(
                actions: actions,
                guards: guards,
                delays: delays,
                reactors: reactors
            )
        )
    }
}

/// Creates a machine setup builder (legacy action/guard handlers without per-invocation params).
public func setup<Context: Sendable>(
    actions legacyActions: [String: @Sendable (ActionArgs<Context>) -> Void] = [:],
    guards legacyGuards: [String: @Sendable (ActionArgs<Context>) -> Bool] = [:],
    delays: [String: @Sendable (ActionArgs<Context>) -> Int] = [:],
    reactors: [String: ReactorLogicEntry] = [:]
) -> MachineSetup<Context> {
    MachineSetup(
        actions: legacyActions,
        guards: legacyGuards,
        delays: delays,
        reactors: reactors
    )
}
