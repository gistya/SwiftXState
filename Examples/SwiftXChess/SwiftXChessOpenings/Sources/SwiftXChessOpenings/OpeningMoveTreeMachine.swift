import Foundation
import SwiftXState

/// The opening book as a typed — but **data-driven** — `StateMachine`: states and transitions are
/// generated from `dataset.nodes` (thousands of positions), so this is the `StateID == String`
/// instantiation of the DSL, built with a result-builder `for`-loop. Was `createMachine` /
/// `MachineConfig` / `StateNodeConfig` assembled in a dictionary loop.
public struct OpeningMoveTreeMachine: StateMachine {
    public typealias Context = OpeningTreeContext
    public typealias StateID = String
    public typealias EventID = String

    public static let id = "opening-move-tree"

    public let dataset: OpeningDataset

    public init(dataset: OpeningDataset = .bundled) { self.dataset = dataset }

    public var context: OpeningTreeContext { .initial(rootId: dataset.rootId) }

    public var machine: some XStateMachine {
        let dataset = self.dataset
        let rootId = dataset.rootId
        for (nodeId, transitions) in dataset.nodes {
            node(nodeId, transitions: transitions, dataset: dataset, isRoot: nodeId == rootId)
        }
    }

    /// One book position: a state per `nodeId`, a transition per move (`eventType -> targetId`) whose
    /// action advances `context.nodeId` / `.ply`.
    private func node(
        _ nodeId: String,
        transitions: [String: String],
        dataset: OpeningDataset,
        isRoot: Bool
    ) -> State {
        let state = State(nodeId) {
            for (eventType, targetId) in transitions {
                Transition(on: eventType, to: targetId).action { (context: OpeningTreeContext) in
                    var ctx = context
                    ctx.nodeId = targetId
                    ctx.ply = dataset.ply(for: targetId)
                    return ctx
                }
            }
        }
        return isRoot ? state.initial() : state
    }

    // MARK: - Resolved-machine builders (for current consumers; cached, since the tree is large)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: ResolvedMachine<OpeningTreeContext>?

    public static func make(dataset: OpeningDataset = .bundled) -> ResolvedMachine<OpeningTreeContext> {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let built = OpeningMoveTreeMachine(dataset: dataset).resolvedMachine(id: id)
        cached = built
        return built
    }

    /// Compact 1-state machine for Stately Inspector — runtime uses the full book tree.
    public static func inspectorSummaryMachine(
        dataset: OpeningDataset = .bundled
    ) -> ResolvedMachine<OpeningTreeContext> {
        OpeningInspectorSummaryMachine(dataset: dataset).resolvedMachine(id: id)
    }

    public static func availableMoves(
        from nodeId: String,
        dataset: OpeningDataset = .bundled
    ) -> [String] {
        guard let transitions = dataset.nodes[nodeId] else { return [] }
        return transitions.keys.compactMap { eventType in
            guard eventType.hasPrefix("SAN.") else { return nil }
            return String(eventType.dropFirst(4))
        }.sorted()
    }
}

extension String {
    /// Atomic state id used in the lightweight inspector graph (runtime uses dataset node ids).
    static var inspectorWireState: String { "tracking" }
}

/// The inspector summary: one `tracking` state with a wildcard `SAN.*` self-transition (the string
/// engine matches the `.*` suffix). The runtime uses the full tree above.
struct OpeningInspectorSummaryMachine: StateMachine {
    typealias Context = OpeningTreeContext
    typealias StateID = String
    typealias EventID = String

    let dataset: OpeningDataset

    var context: OpeningTreeContext { .initial(rootId: dataset.rootId) }

    var machine: some XStateMachine {
        State(.inspectorWireState) {
            Transition(on: "SAN.*", to: .inspectorWireState)
        }
        .initial()
    }
}
