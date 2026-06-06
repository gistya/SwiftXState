import Foundation

/// Given a machine, snapshot, and event, returns the next snapshot and actions to execute.
/// This is a pure function that does not execute actions.
public func transition<Context: Sendable>(
    _ machine: StateMachine<Context>,
    snapshot: MachineSnapshot<Context>,
    event: any Eventable
) -> (snapshot: MachineSnapshot<Context>, actions: [ExecutableAction<Context>]) {
    _ = machine
    let (nextSnapshot, actions, _) = macrostep(snapshot: snapshot, event: event, isInitial: false)
    return (nextSnapshot, actions)
}

/// Returns the initial snapshot and actions from a machine's initial transition.
public func initialTransition<Context: Sendable>(
    _ machine: StateMachine<Context>,
    input: SendableValue? = nil,
    context: Context? = nil
) -> (snapshot: MachineSnapshot<Context>, actions: [ExecutableAction<Context>]) {
    let resolvedContext = resolveInitialContext(machine: machine, input: input, context: context)
    let (snapshot, actions) = initialMicrostep(machine: machine, context: resolvedContext)
    let (finalSnapshot, macrostepActions, _) = macrostep(
        snapshot: snapshot,
        event: SystemEvent.`init`,
        isInitial: true,
        pendingActions: actions
    )
    return (finalSnapshot, macrostepActions)
}