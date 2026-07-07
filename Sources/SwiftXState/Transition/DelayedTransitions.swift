import Foundation

/// Metadata for a delayed (`after`) transition on a state node.
struct AfterSchedule: Sendable {
    let delayKey: String
    let eventType: String
}

/// Creates the event type for a delayed transition, mirroring XState's `createAfterEvent`.
public func createAfterEvent(delayRef: String, stateNodeId: String) -> String {
    "xstate.after.\(delayRef).\(stateNodeId)"
}

func resolveAfterDelay<Context: Sendable>(
    delayKey: String,
    args: ActionArgs<Context>,
    delays: [String: @Sendable (ActionArgs<Context>) -> Int]
) -> Int {
    if let milliseconds = Int(delayKey) {
        return milliseconds
    }
    // A registered named delay wins over duration parsing, preserving existing behavior.
    if let resolver = delays[delayKey] {
        return resolver(args)
    }
    // XState v6 duration strings: "10ms", "5s", ISO-8601 day-time like "PT2M".
    if let milliseconds = parseDurationToMilliseconds(delayKey) {
        return milliseconds
    }
    fatalError("Unknown delay \"\(delayKey)\". Use a numeric delay, a duration string (\"10ms\", \"5s\", \"PT2M\"), or register it via MachineImplementations.delays.")
}

func processAfterConfig<Context: Sendable>(
    _ after: [String: TransitionInput<Context>],
    stateNode: StateNode<Context>
) -> [AfterSchedule] {
    var schedules: [AfterSchedule] = []

    for (delayKey, input) in after {
        let delayRef = Int(delayKey) != nil ? delayKey : delayKey
        let eventType = createAfterEvent(delayRef: delayRef, stateNodeId: stateNode.id)
        let configs = resolveTransitionConfigs(input)

        stateNode.transitions[eventType, default: []].append(
            contentsOf: configs.map { ResolvedTransition(config: $0, source: stateNode) }
        )

        schedules.append(AfterSchedule(delayKey: delayKey, eventType: eventType))
    }

    return schedules
}