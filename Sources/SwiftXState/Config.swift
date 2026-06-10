import Foundation

// MARK: - Machine Configuration

/// Configuration for creating a state machine, mirroring XState's `createMachine` config.
public struct MachineConfig<Context: Sendable>: Sendable {
    /// The machine's id — the root state node's name, used for `#id` targets and in inspection.
    public var id: String?
    /// Key of the initial child state. Required for a compound machine with `states`.
    public var initial: String?
    /// The starting context value.
    public var context: Context?
    /// Builds initial context from actor input, mirroring XState's `context: ({ input }) => …`.
    public var contextFromInput: (@Sendable (SendableValue?) -> Context)?
    /// Child state nodes, keyed by name.
    public var states: [String: StateNodeConfig<Context>]
    /// Root-level event transitions — handled regardless of the current state.
    public var on: [String: TransitionInput<Context>]?
    /// Actions run when the machine starts (its root state is entered).
    public var entry: [ActionRef<Context>]?
    /// Actions run when the machine stops (its root state is exited).
    public var exit: [ActionRef<Context>]?
    /// Root node type — e.g. `.parallel` for a parallel machine.
    public var type: StateNodeType?
    /// Produces the machine's output when it reaches a top-level final state.
    public var output: OutputResolver<Context>?
    /// Optional human-readable description, carried into the exported definition JSON.
    public var description: String?

    public init(
        id: String? = nil,
        initial: String? = nil,
        context: Context? = nil,
        contextFromInput: (@Sendable (SendableValue?) -> Context)? = nil,
        states: [String: StateNodeConfig<Context>] = [:],
        on: [String: TransitionInput<Context>]? = nil,
        entry: [ActionRef<Context>]? = nil,
        exit: [ActionRef<Context>]? = nil,
        type: StateNodeType? = nil,
        output: OutputResolver<Context>? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.initial = initial
        self.context = context
        self.contextFromInput = contextFromInput
        self.states = states
        self.on = on
        self.entry = entry
        self.exit = exit
        self.type = type
        self.output = output
        self.description = description
    }
}

/// Configuration for a single state node.
public struct StateNodeConfig<Context: Sendable>: Sendable {
    /// Explicit id for this node, enabling `#id` absolute targets (defaults to the dotted path).
    public var id: String?
    /// Key of the initial child state (for a compound node).
    public var initial: String?
    /// The node type. Defaults to `.atomic` (leaf) or `.compound` (has `states`) if unset.
    public var type: StateNodeType?
    /// Nested child states, keyed by name.
    public var states: [String: StateNodeConfig<Context>]?
    /// Event transitions handled while this state is active.
    public var on: [String: TransitionInput<Context>]?
    /// Transitions taken when all child regions of this compound/parallel state complete.
    public var onDone: TransitionInput<Context>?
    /// Eventless ("always") transitions — re-evaluated after every microstep while active.
    public var always: [TransitionConfig<Context>]?
    /// Delayed transitions — keys are delay in milliseconds or a named delay reference.
    public var after: [String: TransitionInput<Context>]?
    /// Actors invoked while this state is active (`fromTask`, `fromCallback`, child machines, …).
    public var invoke: [InvokeConfig<Context>]?
    /// Actions run when this state is entered.
    public var entry: [ActionRef<Context>]?
    /// Actions run when this state is exited.
    public var exit: [ActionRef<Context>]?
    /// Tags exposed on the snapshot while this state is active (`snapshot.hasTag(_:)`).
    public var tags: [String]?
    /// Arbitrary metadata attached to this node (`snapshot.getMeta()`), exported to the definition.
    public var meta: [String: SendableValue]?
    /// Produces output when this state is a final state that completes.
    public var output: OutputResolver<Context>?
    /// Optional human-readable description, carried into the exported definition JSON.
    public var description: String?
    /// For a `.history` node: whether it restores shallow or deep history.
    public var history: HistoryType?
    /// Default target when a history state has no stored history (e.g. `target: "bar"`).
    public var target: String?

    public init(
        id: String? = nil,
        initial: String? = nil,
        type: StateNodeType? = nil,
        states: [String: StateNodeConfig<Context>]? = nil,
        on: [String: TransitionInput<Context>]? = nil,
        onDone: TransitionInput<Context>? = nil,
        always: [TransitionConfig<Context>]? = nil,
        after: [String: TransitionInput<Context>]? = nil,
        invoke: [InvokeConfig<Context>]? = nil,
        entry: [ActionRef<Context>]? = nil,
        exit: [ActionRef<Context>]? = nil,
        tags: [String]? = nil,
        meta: [String: SendableValue]? = nil,
        output: OutputResolver<Context>? = nil,
        description: String? = nil,
        history: HistoryType? = nil,
        target: String? = nil
    ) {
        self.id = id
        self.initial = initial
        self.type = type
        self.states = states
        self.on = on
        self.onDone = onDone
        self.always = always
        self.after = after
        self.invoke = invoke
        self.entry = entry
        self.exit = exit
        self.tags = tags
        self.meta = meta
        self.output = output
        self.description = description
        self.history = history
        self.target = target
    }
}

/// Transition input — supports XState's string shorthand, single config, or array.
public enum TransitionInput<Context: Sendable>: Sendable {
    /// Bare target shorthand, e.g. `"active"` — equivalent to `.to("active")`.
    case target(String)
    /// One fully-specified transition (target + guard + actions).
    case single(TransitionConfig<Context>)
    /// An ordered list of candidate transitions; the first whose guard passes is taken.
    case multiple([TransitionConfig<Context>]) // swiftlint:disable:this line_length

    /// Convenience for a target-only transition: `on: ["GO": .to("active")]`.
    public static func to(_ target: String) -> TransitionInput<Context> {
        .target(target)
    }
}

/// The type of a state node.
public enum StateNodeType: Sendable {
    /// A leaf state with no children.
    case atomic
    /// A state with child states, one of which is active at a time.
    case compound
    /// A state whose child regions are all active simultaneously.
    case parallel
    /// A terminal state; entering it completes its parent (and can emit output).
    case final
    /// A pseudo-state that restores the parent's previously-active child on re-entry.
    case history
}

/// Whether a history state restores only the direct child (`shallow`) or the full nested
/// configuration (`deep`).
public enum HistoryType: Sendable {
    case shallow
    case deep
}

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

/// A reference to an action. Build these with the helper functions (`assign`, `sendTo`, `raise`,
/// `log`, `spawnChild`, …) rather than constructing cases directly.
public enum ActionRef<Context: Sendable>: Sendable {
    /// A guard/action registered by name via `setup(actions:)`.
    case named(String)
    /// A named action with bound parameters (see `actionRef(_:params:)`).
    case parameterized(String, ParamsBox)
    /// Update context (`assign { … }`).
    case assign(AssignAction<Context>)
    /// An inline, unnamed action closure.
    case inline(@Sendable (ActionArgs<Context>) -> Void)
    /// Spawn a child actor.
    case spawn(SpawnRef<Context>)
    /// Stop a spawned/invoked child.
    case stopChild(ChildTarget<Context>)
    /// Forward the current event to a child.
    case forwardTo(ChildTarget<Context>)
    /// Send an event to another actor.
    case sendTo(SendToAction<Context>)
    /// Send an event to the parent actor.
    case sendParent(Event)
    /// Raise an event back into this machine (processed in the same or a later step).
    case raise(RaiseAction<Context>)
    /// Cancel a previously-scheduled delayed `raise`/`sendTo` by id.
    case cancel(CancelId<Context>)
    /// Imperatively enqueue actions/guards (`enqueueActions { … }`).
    case enqueueActions(@Sendable (EnqueueActionsBuilder<Context>) -> Void)
    /// Emit a log line.
    case log(LogAction<Context>)
    /// Emit an event to external subscribers.
    case emit(EmitAction<Context>)
}

/// A context update. Prefer the `assign` helper functions over constructing cases directly.
public enum AssignAction<Context: Sendable>: Sendable {
    /// Per-property assigners, each producing the new value from `(context, event)`.
    case properties([String: @Sendable (ActionArgs<Context>) -> SendableValue])
    /// A single mutating closure over the whole context.
    case function(@Sendable (inout Context, ActionArgs<Context>) -> Void)
}

/// A type-erased sendable value for context properties.
public struct SendableValue: @unchecked Sendable, Equatable {
    private let box: any Sendable & Equatable

    public init<T: Sendable & Equatable>(_ value: T) {
        self.box = value
    }

    public func get<T: Sendable & Equatable>(_ type: T.Type = T.self) -> T? {
        box as? T
    }

    public static func == (lhs: SendableValue, rhs: SendableValue) -> Bool {
        guard let l = lhs.box as (any Equatable)?, let r = rhs.box as (any Equatable)? else {
            return false
        }
        return String(describing: l) == String(describing: r)
    }

    var boxedForInspection: Any { box }
}

/// The arguments every guard and action receives: the current `context` and the triggering `event`.
public struct ActionArgs<Context: Sendable>: Sendable {
    /// The machine's current context.
    public let context: Context
    /// The event that triggered this guard/action. Downcast it (or use the Tier-2 typed API).
    public let event: any Eventable

    public init(context: Context, event: any Eventable) {
        self.context = context
        self.event = event
    }
}

/// A reference to a guard. Build with `.inline { … }`, `.named("…")`, `guardRef(_:params:)`,
/// or the composite combinators `and` / `or` / `not`.
public indirect enum GuardRef<Context: Sendable>: Sendable {
    /// A guard registered by name via `setup(guards:)`.
    case named(String)
    /// A named guard with bound parameters.
    case parameterized(String, ParamsBox)
    /// An inline predicate over `(context, event)`.
    case inline(@Sendable (ActionArgs<Context>) -> Bool)
    /// A boolean combination of other guards.
    case composite(CompositeGuard<Context>)
}

/// A boolean combination of guards — build with `and(_:_:)`, `or(_:_:)`, `not(_:)`, or `.stateIn`.
public indirect enum CompositeGuard<Context: Sendable>: Sendable {
    /// All sub-guards must pass.
    case and([GuardRef<Context>])
    /// At least one sub-guard must pass.
    case or([GuardRef<Context>])
    /// The sub-guard must fail.
    case not(GuardRef<Context>)
    /// Passes when the machine is currently in the given state path (XState's `stateIn`).
    case stateIn(String)
}

/// Resolves output from a final state.
public typealias OutputResolver<Context: Sendable> = @Sendable (ActionArgs<Context>) -> SendableValue?

// MARK: - Transition Input Resolution

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

// MARK: - Initial Context Resolution

/// Resolves the initial context for a machine, mirroring XState actor `input` + context initializer.
public func resolveInitialContext<Context: Sendable>(
    machine: StateMachine<Context>,
    input: SendableValue? = nil,
    context: Context? = nil
) -> Context {
    if let context {
        return context
    }
    if let contextFromInput = machine.config.contextFromInput {
        return contextFromInput(input)
    }
    if let staticContext = machine.config.context {
        return staticContext
    }
    fatalError(
        "No context provided for machine \"\(machine.id)\". " +
            "Provide context in MachineConfig, contextFromInput, or start(input:)/start(context:)."
    )
}
