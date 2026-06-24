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

    /// Optional background driver. A *runnable* logic (the shape behind callback / task / observable
    /// children) pushes a stream of snapshots through `scope` from its own task rather than folding
    /// events. Pure reducers (including `MachineLogic`) leave this as the no-op default.
    func run(_ scope: ActorScope<Snapshot>) async

    /// Produce the initial snapshot, *running any startup side effects* against the host. The default
    /// is the pure `initialState` (no effects). An effectful logic (`MachineLogic`) overrides this to
    /// run entry actions / initial `after` / initial `invoke` through the host's runtime resources.
    func started<H: MachineHost>(input: SendableValue?, host: isolated H) async -> Snapshot

    /// Fold one event into the next snapshot, *running any side effects* against the host. The
    /// default is the pure `step`. `MachineLogic` overrides this to run the macrostep's side-effect
    /// actions, reschedule `after`, and reconcile `invoke` children — all via `host`'s primitives.
    func handle<H: MachineHost>(_ event: any Eventable, _ snapshot: Snapshot, host: isolated H) async -> Snapshot
}

extension ActorLogic {
    func run(_ scope: ActorScope<Snapshot>) async {}

    func started<H: MachineHost>(input: SendableValue?, host: isolated H) async -> Snapshot {
        initialState(input: input)
    }

    func handle<H: MachineHost>(_ event: any Eventable, _ snapshot: Snapshot, host: isolated H) async -> Snapshot {
        step(snapshot, on: event)
    }
}

/// Handed to `ActorLogic.run` so a background driver can push new snapshots into its host actor.
/// `update` hops onto the actor's isolation; updates after the logic is no longer `.active` are
/// dropped by the host (mirroring run-to-completion).
struct ActorScope<Snapshot: Sendable>: Sendable {
    let update: @Sendable (Snapshot) async -> Void
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
