/// Configuration for a transition.
public struct TransitionConfig<Context: Sendable>: Sendable {
    /// Target state: a sibling key (`"yellow"`), a relative path (`".child"`), or `#absolute`.
    /// `nil` is an internal (no-transition) action-only transition.
    public var target: String?
    /// Multiple targets for parallel regions, mirroring XState's `target: ['.a', '.b']`.
    public var targets: [String]?
    /// Guard that must pass for this transition to be taken.
    public var guardRef: GuardRef<Context>?
    /// Actions executed when this transition is taken.
    public var actions: [ActionRef<Context>]?
    /// Force re-entry (exit + re-enter the target) even on a self-transition.
    public var reenter: Bool?
    /// Optional human-readable description, carried into the exported definition JSON.
    public var description: String?

    public init(
        target: String? = nil,
        targets: [String]? = nil,
        guard condition: GuardRef<Context>? = nil,
        actions: [ActionRef<Context>]? = nil,
        reenter: Bool? = nil,
        description: String? = nil
    ) {
        self.target = target
        self.targets = targets
        self.guardRef = condition
        self.actions = actions
        self.reenter = reenter
        self.description = description
    }
}

func resolveTransitionConfigs<Context: Sendable>(
    _ input: TransitionInput<Context>
) -> [TransitionConfig<Context>] {
    switch input {
    case let .target(target):
        return [TransitionConfig(target: target)]
    case let .single(config):
        return [config]
    case let .multiple(configs):
        return configs
    }
}
