
/// A state machine definition — the pure, reusable logic of a statechart. Created with
/// `createMachine(_:)` and run by `createActor(_:)`. Stateless and `Sendable`: one machine can
/// back many actors. Use `provide(_:)` to swap in implementations.
public final class ResolvedMachine<Context: Sendable>: @unchecked Sendable {
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
            config: Self.rootConfig(from: config),
            parent: nil,
            machineId: self.id
        )
        self.root.bind(machine: self)
    }

    /// Override implementations, mirroring XState's `machine.provide()`.
    public func provide(_ implementations: MachineImplementations<Context>) -> ResolvedMachine<Context> {
        let merged = MachineImplementations(
            actions: self.implementations.actions.merging(implementations.actions) { _, new in new },
            guards: self.implementations.guards.merging(implementations.guards) { _, new in new },
            delays: self.implementations.delays.merging(implementations.delays) { _, new in new },
            actors: self.implementations.actors.merging(implementations.actors) { _, new in new }
        )
        let machine = ResolvedMachine(config: config, implementations: merged)
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
    
    private static func rootConfig(from config: MachineConfig<Context>) -> StateNodeConfig<Context> {
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
}

/// Resolves the initial context for a machine, mirroring XState actor `input` + context initializer.
public func resolveInitialContext<Context: Sendable>(
    machine: ResolvedMachine<Context>,
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
