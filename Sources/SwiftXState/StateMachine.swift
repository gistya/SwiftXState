import Foundation

/// Machine implementations provided at interpretation time (actions, guards).
/// Registered actor logic for named `invoke` / `spawnChild` sources.
public struct ActorLogicEntry: Sendable {
    public var machine: MachineActorLogicBox?
    public var task: TaskActorLogicBox?
    public var callback: CallbackActorLogicBox?
    public var taskGroup: TaskGroupActorLogicBox?
    public var transition: TransitionActorLogicBox?
    public var observable: ObservableActorLogicBox?
    public var store: StoreActorLogicBox?

    public init(machine: MachineActorLogicBox) {
        self.machine = machine
        self.task = nil
        self.callback = nil
        self.taskGroup = nil
        self.transition = nil
        self.observable = nil
        self.store = nil
    }

    public init(task: TaskActorLogicBox) {
        self.machine = nil
        self.task = task
        self.callback = nil
        self.taskGroup = nil
        self.transition = nil
        self.observable = nil
        self.store = nil
    }

    public init(callback: CallbackActorLogicBox) {
        self.machine = nil
        self.task = nil
        self.callback = callback
        self.taskGroup = nil
        self.transition = nil
        self.observable = nil
        self.store = nil
    }

    public init(taskGroup: TaskGroupActorLogicBox) {
        self.machine = nil
        self.task = nil
        self.callback = nil
        self.taskGroup = taskGroup
        self.transition = nil
        self.observable = nil
        self.store = nil
    }

    public init(transition: TransitionActorLogicBox) {
        self.machine = nil
        self.task = nil
        self.callback = nil
        self.taskGroup = nil
        self.transition = transition
        self.observable = nil
        self.store = nil
    }

    public init(observable: ObservableActorLogicBox) {
        self.machine = nil
        self.task = nil
        self.callback = nil
        self.taskGroup = nil
        self.transition = nil
        self.observable = observable
        self.store = nil
    }

    public init(store: StoreActorLogicBox) {
        self.machine = nil
        self.task = nil
        self.callback = nil
        self.taskGroup = nil
        self.transition = nil
        self.observable = nil
        self.store = store
    }

    public init(_ source: ActorSource) {
        switch source {
        case let .machine(machine):
            self.machine = machine
            self.task = nil
            self.callback = nil
            self.taskGroup = nil
            self.transition = nil
            self.observable = nil
            self.store = nil
        case let .task(task):
            self.machine = nil
            self.task = task
            self.callback = nil
            self.taskGroup = nil
            self.transition = nil
            self.observable = nil
            self.store = nil
        case let .callback(callback):
            self.machine = nil
            self.task = nil
            self.callback = callback
            self.taskGroup = nil
            self.transition = nil
            self.observable = nil
            self.store = nil
        case let .taskGroup(taskGroup):
            self.machine = nil
            self.task = nil
            self.callback = nil
            self.taskGroup = taskGroup
            self.transition = nil
            self.observable = nil
            self.store = nil
        case let .transition(transition):
            self.machine = nil
            self.task = nil
            self.callback = nil
            self.taskGroup = nil
            self.transition = transition
            self.observable = nil
            self.store = nil
        case let .observable(observable):
            self.machine = nil
            self.task = nil
            self.callback = nil
            self.taskGroup = nil
            self.transition = nil
            self.observable = observable
            self.store = nil
        case let .store(store):
            self.machine = nil
            self.task = nil
            self.callback = nil
            self.taskGroup = nil
            self.transition = nil
            self.observable = nil
            self.store = store
        case .named:
            fatalError("Cannot create ActorLogicEntry from .named source")
        }
    }
}

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

/// A state machine definition — the pure, reusable logic of a statechart. Created with
/// `createMachine(_:)` and run by `createActor(_:)`. Stateless and `Sendable`: one machine can
/// back many actors. Use `provide(_:)` to swap in implementations.
public final class StateMachine<Context: Sendable>: @unchecked Sendable {
    /// The machine id (root state node name); `"(machine)"` if none was set.
    public let id: String
    /// The configuration this machine was built from.
    public let config: MachineConfig<Context>
    /// The named actions/guards/delays/actors backing this machine.
    public var implementations: MachineImplementations<Context>
    /// The root state node of the resolved state tree.
    public let root: StateNode<Context>
    /// The root's direct child states, keyed by name.
    public var states: [String: StateNode<Context>] { root.states }
    /// Every event type the machine can handle, sorted.
    public var events: [String] { Array(root.eventTypes()).sorted() }
    var idMap: [String: StateNode<Context>] = [:]

    init(config: MachineConfig<Context>, implementations: MachineImplementations<Context> = MachineImplementations<Context>()) {
        self.config = config
        self.implementations = implementations
        self.id = config.id ?? "(machine)"
        self.root = StateNode(
            key: "",
            config: rootConfig(from: config),
            parent: nil,
            machineId: self.id
        )
        self.root.bind(machine: self)
    }

    /// Override implementations, mirroring XState's `machine.provide()`.
    public func provide(_ implementations: MachineImplementations<Context>) -> StateMachine<Context> {
        let merged = MachineImplementations(
            actions: self.implementations.actions.merging(implementations.actions) { _, new in new },
            guards: self.implementations.guards.merging(implementations.guards) { _, new in new },
            delays: self.implementations.delays.merging(implementations.delays) { _, new in new },
            actors: self.implementations.actors.merging(implementations.actors) { _, new in new }
        )
        let machine = StateMachine(config: config, implementations: merged)
        return machine
    }

    func resolveTarget(_ target: String, from source: StateNode<Context>) -> [StateNode<Context>] {
        if target.isEmpty { return [] }

        if target.hasPrefix("#") {
            let id = String(target.dropFirst())
            if let node = idMap[id] { return [node] }
            if let node = idMap["\(self.id).\(id)"] { return [node] }
            return []
        }

        let segments = target.split(separator: ".").map(String.init)
        var current: StateNode<Context>? = source
        var results: [StateNode<Context>] = []

        for (index, segment) in segments.enumerated() {
            if segment.isEmpty {
                // Relative target like ".childState"
                if index == 0, let parent = source.parent {
                    current = parent
                }
                continue
            }

            if segment == "#" {
                current = root
                continue
            }

            if let node = current?.states[segment] {
                current = node
            } else if let parent = current?.parent ?? source.parent, let node = parent.states[segment] {
                current = node
            } else if let node = idMap["\(id).\(segment)"] {
                current = node
            } else if let node = idMap[segment] {
                current = node
            } else {
                return []
            }
        }

        if let current {
            results = [current]
            if current.type != .history {
                results.append(contentsOf: getDescendants(current))
            }
        }

        return results
    }

    private func getDescendants(_ node: StateNode<Context>) -> [StateNode<Context>] {
        var result: [StateNode<Context>] = []
        if node.type == .parallel {
            for child in node.states.values where child.type != .history {
                result.append(contentsOf: getInitialStateNodes(child))
            }
        } else if let initial = node.initial, let child = node.states[initial] {
            result.append(contentsOf: getInitialStateNodes(child))
        }
        return result
    }

    func getInitialStateNodes(_ node: StateNode<Context>) -> [StateNode<Context>] {
        var nodes = [node]
        if node.type == .parallel {
            for child in node.states.values where child.type != .history {
                nodes.append(contentsOf: getInitialStateNodes(child))
            }
        } else if let initial = node.initial, let child = node.states[initial] {
            nodes.append(contentsOf: getInitialStateNodes(child))
        }
        return nodes
    }

    func getStateNode(byPath path: [String]) -> StateNode<Context>? {
        var current: StateNode<Context>? = root
        for segment in path {
            guard let node = current?.states[segment] else { return nil }
            current = node
        }
        return current
    }
}

private func rootConfig<Context: Sendable>(from config: MachineConfig<Context>) -> StateNodeConfig<Context> {
    StateNodeConfig(
        id: config.id,
        initial: config.initial,
        type: config.type,
        states: config.states.isEmpty ? nil : config.states,
        on: config.on,
        entry: config.entry,
        exit: config.exit,
        output: config.output,
        description: config.description
    )
}

/// Creates a state machine from a configuration — the Swift equivalent of XState's
/// `createMachine({ … })`. Optionally supply the `implementations` (named actions/guards/actors)
/// referenced by the config; you can also add them later with `provide(_:)` or up front via `setup`.
///
/// ```swift
/// let toggle = createMachine(MachineConfig(
///     id: "toggle", initial: "off", context: EmptyContext(),
///     states: [
///         "off": StateNodeConfig(on: ["TOGGLE": .to("on")]),
///         "on":  StateNodeConfig(on: ["TOGGLE": .to("off")]),
///     ]))
/// ```
public func createMachine<Context: Sendable>(
    _ config: MachineConfig<Context>,
    implementations: MachineImplementations<Context> = MachineImplementations<Context>()
) -> StateMachine<Context> {
    StateMachine(config: config, implementations: implementations)
}