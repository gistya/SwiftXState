import Foundation

/// The state-machine `ActorLogic`: the reducer that drives a `Actor<MachineLogic<Context>>`,
/// which is the generic actor's machine specialization (full parity with `Actor`).
///
/// This type owns only what is genuinely pure — the initial snapshot and the macrostep (`reduce`).
/// The machine-shaped *orchestration* (running side effects, scheduling `after`, spawning `invoke`
/// children) lives in the effectful conformance (`MachineLogic+Host.swift`), run against the host's
/// Context-agnostic primitives. Keeping that split honest is what lets this be a plain `Sendable`
/// value: given a snapshot and an event it computes the next snapshot, and nothing else.
public struct MachineLogic<Context: Sendable>: Sendable {
    public let machine: StateMachine<Context>
    /// Optional start-time context override (replaces the machine's resolved initial context, and
    /// the decoded context on restore). Lets the machine `Actor`'s `start(context:)` thread through
    /// without a separate start signature. Default: none.
    public var contextOverride: Context? = nil

    public init(machine: StateMachine<Context>, contextOverride: Context? = nil) {
        self.machine = machine
        self.contextOverride = contextOverride
    }

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
