import Foundation

/// The **reducer** behind a state-machine `StateActor`: the pure transition logic, separated from
/// the actor's runtime resources (timers, children, effect dispatch). This is the in-package form
/// of the engine-wrap spike's `MachineLogic`, and the first conformer the eventual
/// `StateActor<Logic, ID>` will be parameterized over.
///
/// It owns only what is genuinely pure — the initial snapshot and the macrostep. The machine-shaped
/// *orchestration* (scheduling `after`, spawning `invoke` children) and the side-effect dispatch
/// stay on `StateActor`, which owns the resources they touch. Keeping that split honest is what lets
/// this type be a plain `Sendable` value: given a snapshot and an event it computes the next
/// snapshot plus the effects to run, and nothing else.
struct MachineLogic<Context: Sendable>: Sendable {
    let machine: StateMachine<Context>

    /// The machine's initial snapshot and entry actions (the initial macrostep, run to completion).
    func initialSnapshot(
        input: SendableValue?,
        context: Context?
    ) -> (snapshot: MachineSnapshot<Context>, actions: [ExecutableAction<Context>]) {
        initialTransition(machine, input: input, context: context)
    }

    /// One run-to-completion step: the next snapshot and the side-effect actions it produced.
    /// Microsteps are not recorded (the runtime that needs them — inspection — isn't wired to this
    /// reducer yet; see `StateActor`).
    func reduce(
        _ snapshot: MachineSnapshot<Context>,
        on event: any Eventable
    ) -> (snapshot: MachineSnapshot<Context>, actions: [ExecutableAction<Context>]) {
        let (next, actions, _) = macrostep(
            snapshot: snapshot,
            event: event,
            isInitial: false,
            recordMicrosteps: false
        )
        return (next, actions)
    }
}
