/// A resolved transition with source state node reference.
public struct ResolvedTransition<Context: Sendable>: Sendable {
    public let config: TransitionConfig<Context>
    public unowned let source: StateNode<Context>
    public let reenter: Bool

    init(config: TransitionConfig<Context>, source: StateNode<Context>) {
        self.config = config
        self.source = source
        self.reenter = config.reenter ?? false
    }

    /// Lazily resolved target nodes (requires machine binding).
    public var target: [StateNode<Context>]? {
        guard let machine = source.machine else { return nil }

        if let targets = config.targets {
            let nodes = targets.flatMap { machine.resolveTarget($0, from: source) }
            return nodes.isEmpty ? nil : nodes
        }

        guard let targetString = config.target else { return nil }
        return machine.resolveTarget(targetString, from: source)
    }
}
