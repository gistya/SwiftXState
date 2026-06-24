import Foundation

/// **Experimental — generics refactor.** The behaviour an actor runs, abstracted away from *how*
/// it is run. A conformer supplies an opaque `Snapshot`, its initial value, and a pure step that
/// folds one event into the next snapshot — exactly the surface a mailbox/run-to-completion loop
/// needs, and nothing machine-specific.
///
/// This is the seam the eventual `StateActor<Logic, ID>` is parameterized over. It is deliberately
/// the *pure reducer* slice: it has no notion of side effects, `after` timers, or `invoke` children
/// (those need the actor's runtime resources and are intrinsically machine-shaped). A logic whose
/// step produces no side effects — a hand-written reducer, or a state machine that only transitions
/// / `assign`s / runs `always` — is fully expressible here. `MachineLogic` conforms (below), so the
/// generic `LogicActor` can host any effect-free machine; effectful machines still need
/// `StateActor`'s orchestration until that, too, is folded in.
protocol ActorLogic: Sendable {
    associatedtype Snapshot: Sendable

    /// The snapshot the actor starts in. `input` mirrors a machine's `contextFromInput`.
    func initialState(input: SendableValue?) -> Snapshot

    /// Fold one event into the next snapshot. Pure — no I/O, no scheduling.
    func step(_ snapshot: Snapshot, on event: any Eventable) -> Snapshot

    /// Lifecycle status of a snapshot. The runtime stops feeding events once this is not `.active`.
    func status(of snapshot: Snapshot) -> SnapshotStatus
}

/// `MachineLogic` is an `ActorLogic`: its reducer *is* the macrostep. For an effect-free machine
/// this conformance is total — `LogicActor<MachineLogic<C>>` reaches the same snapshots as `Actor`.
/// For an effectful machine the `step` still computes the right *next snapshot*; what it omits is
/// the running of side effects / `after` / `invoke`, which `LogicActor` does not (yet) perform.
extension MachineLogic: ActorLogic {
    func initialState(input: SendableValue?) -> MachineSnapshot<Context> {
        initialSnapshot(input: input, context: nil).snapshot
    }

    func step(_ snapshot: MachineSnapshot<Context>, on event: any Eventable) -> MachineSnapshot<Context> {
        reduce(snapshot, on: event).snapshot
    }

    func status(of snapshot: MachineSnapshot<Context>) -> SnapshotStatus {
        snapshot.status
    }
}
