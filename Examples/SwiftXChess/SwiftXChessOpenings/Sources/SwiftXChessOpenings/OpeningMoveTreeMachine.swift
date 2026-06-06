import Foundation
import SwiftXState

public enum OpeningMoveTreeMachine {
    public static let id = "opening-move-tree"
    /// Atomic state id used in the lightweight inspector graph (runtime uses dataset node ids).
    public static let inspectorWireState = "tracking"

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: StateMachine<OpeningTreeContext>?

    /// Compact machine for Stately Inspector — runtime uses the full book tree.
    public static func inspectorSummaryMachine(
        dataset: OpeningDataset = .bundled
    ) -> StateMachine<OpeningTreeContext> {
        createMachine(
            MachineConfig(
                id: id,
                initial: inspectorWireState,
                context: .initial(rootId: dataset.rootId),
                states: [
                    inspectorWireState: StateNodeConfig(
                        on: [
                            "SAN.*": .single(
                                TransitionConfig(target: inspectorWireState)
                            ),
                        ],
                        description: "On book — context.nodeId is the position in the full opening tree"
                    ),
                ],
                description: "Opening book tracker (inspector summary; runtime tree is off-graph)"
            )
        )
    }

    public static func make(dataset: OpeningDataset = .bundled) -> StateMachine<OpeningTreeContext> {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let built = build(dataset: dataset)
        cached = built
        return built
    }

    private static func build(dataset: OpeningDataset) -> StateMachine<OpeningTreeContext> {
        var stateConfigs: [String: StateNodeConfig<OpeningTreeContext>] = [:]

        for (nodeId, transitions) in dataset.nodes {
            var on: [String: TransitionInput<OpeningTreeContext>] = [:]
            for (eventType, targetId) in transitions {
                on[eventType] = .single(
                    TransitionConfig(
                        target: targetId,
                        actions: [
                            assign { context, _ in
                                context.nodeId = targetId
                                context.ply = dataset.ply(for: targetId)
                            },
                        ]
                    )
                )
            }
            stateConfigs[nodeId] = StateNodeConfig(on: on)
        }

        return createMachine(
            MachineConfig(
                id: id,
                initial: dataset.rootId,
                context: .initial(rootId: dataset.rootId),
                states: stateConfigs,
                description: "Pure opening move-tree (no chess semantics)"
            )
        )
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