/// A resolved transition with source state node reference.
public struct ResolvedTransition<Context: Sendable>: Sendable {
    public let config: TransitionConfig<Context>
    // `unowned` avoids a retain on the owning node. Embedded Swift prohibits `unowned` as well as
    // `weak` (only `unowned(unsafe)` survives, which trades a nil check for a dangling pointer), so
    // there the reference is strong — see BackRef.swift for why that is sound.
    #if hasFeature(Embedded)
    public let source: StateNode<Context>
    #else
    public unowned let source: StateNode<Context>
    #endif
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
