import Foundation

/// The behaviour an actor runs, abstracted away from how it is run. A conformer supplies an
/// opaque `Snapshot`, its initial value, and a pure step that folds one event into the next
/// snapshot — exactly the surface a mailbox/run-to-completion loop needs, and nothing machine-specific.
///
/// This is the protocol the eventual `StateActor<Logic, ID>` is parameterized over. It is deliberately
/// the pure reducer aspect: it has no notion of side effects, `after` timers, or `invoke` children
/// (those need the actor's runtime resources and are intrinsically machine-shaped). A logic whose
/// step produces no side effects — a hand-written reducer, or a state machine that only transitions
/// / `assign`s / runs `always` — is fully expressible here. `MachineLogic` conforms (below), so the
/// generic `Actor` can host any effect-free machine; effectful machines still need
/// `StateActor`'s orchestration until that, too, is folded in.
public protocol ActorLogic: Sendable {
    associatedtype Snapshot: Sendable

    /// The snapshot the actor starts in. `input` mirrors a machine's `contextFromInput`.
    func initialState(input: SendableValue?) -> Snapshot

    /// Fold one event into the next snapshot. Pure — no I/O, no scheduling.
    func step(_ snapshot: Snapshot, on event: any Eventable) -> Snapshot

    /// Lifecycle status of a snapshot. The runtime stops feeding events once this is not `.active`.
    func status(of snapshot: Snapshot) -> SnapshotStatus

    /// Optional background driver. A *runnable* logic (the shape behind callback / task / observable
    /// children) drives itself through `scope` — registering `receive` handlers, pushing snapshots,
    /// and producing `sendToParent`/`emit` effects — rather than folding events. Returns an optional
    /// cleanup run on `stop()` (XState's `fromCallback` dispose). Pure reducers (incl. `MachineLogic`)
    /// leave this as the no-op default.
    func run(_ scope: ActorScope<Snapshot>) async -> (@Sendable () -> Void)?

    /// **Synchronous** startup setup, run during `start()` before it returns — so receivers and the
    /// dispose are in place before any `send` (callback children rely on this, matching
    /// `CallbackChildRef.start`). Returns an optional cleanup run on `stop()`. Streaming logics that
    /// need a long-running task use `run` instead; reducers/machines leave this nil.
    func setUp(_ scope: ActorScope<Snapshot>) -> (@Sendable () -> Void)?

    /// Produce the initial snapshot, *running any startup side effects* against the host. The default
    /// is the pure `initialState` (no effects). An effectful logic (`MachineLogic`) overrides this to
    /// run entry actions / initial `after` / initial `invoke` through the host's runtime resources.
    func started<H: MachineHost>(input: SendableValue?, host: isolated H) async -> Snapshot

    /// Fold one event into the next snapshot, *running any side effects* against the host. The
    /// default is the pure `step`. `MachineLogic` overrides this to run the macrostep's side-effect
    /// actions, reschedule `after`, and reconcile `invoke` children — all via `host`'s primitives.
    func handle<H: MachineHost>(_ event: any Eventable, _ snapshot: Snapshot, host: isolated H) async -> Snapshot

    // Inspection hooks — declared as requirements (not just extension methods) so a generic
    // `Actor<L>` dispatches to the conformer's override, not the no-op default.
    var providesInspection: Bool { get }
    func inspectionMachineId() -> String?
    func inspectionRegistrationEvent(
        _ snapshot: Snapshot, actor: InspectionActorRef, rootId: String,
        parentSessionId: String?, includeDefinition: Bool
    ) -> InspectionEvent?
    func inspectionTransitionEvent(
        _ snapshot: Snapshot, event: any Eventable, actor: InspectionActorRef, rootId: String
    ) -> InspectionEvent?
    func inspectionSnapshotEvent(
        _ snapshot: Snapshot, event: any Eventable, actor: InspectionActorRef, rootId: String
    ) -> InspectionEvent?

    /// The inspectable action types run during startup, in order — emitted as `@xstate.action`
    /// events *after* the actor's registration (matching Actor's start ordering). Default: none.
    func startupActionTypes(input: SendableValue?) -> [String]

    /// The snapshot to publish when the actor is stopped (status `.stopped`). The runtime notifies
    /// observers with this on `stop()`, so waiters (`waitFor`, child refs) see termination. Default:
    /// the snapshot unchanged.
    func stoppedSnapshot(_ snapshot: Snapshot) -> Snapshot

    /// Output carried in the `DoneActorEvent` when a child reaches `.done` via its snapshot (machine
    /// children). Default nil.
    func output(of snapshot: Snapshot) -> SendableValue?

    /// The string value used in a child's `SnapshotActorEvent` (syncSnapshot machine children).
    /// Default nil.
    func childSnapshotValue(of snapshot: Snapshot) -> String?
}

public extension ActorLogic {
    func run(_ scope: ActorScope<Snapshot>) async -> (@Sendable () -> Void)? { nil }

    func setUp(_ scope: ActorScope<Snapshot>) -> (@Sendable () -> Void)? { nil }

    func started<H: MachineHost>(input: SendableValue?, host: isolated H) async -> Snapshot {
        initialState(input: input)
    }

    func handle<H: MachineHost>(_ event: any Eventable, _ snapshot: Snapshot, host: isolated H) async -> Snapshot {
        step(snapshot, on: event)
    }

    // MARK: Inspection hooks (default: not inspected; `MachineLogic` builds the machine events)

    /// Whether this logic emits inspection events at all. Pure reducers / runnables don't.
    var providesInspection: Bool { false }

    /// The machine id for this logic's inspection actor ref, if any.
    func inspectionMachineId() -> String? { nil }

    /// The `@xstate.actor` registration event, or nil if this logic isn't inspected.
    func inspectionRegistrationEvent(
        _ snapshot: Snapshot, actor: InspectionActorRef, rootId: String,
        parentSessionId: String?, includeDefinition: Bool
    ) -> InspectionEvent? { nil }

    /// The `@xstate.transition` event for a settled snapshot, or nil.
    func inspectionTransitionEvent(
        _ snapshot: Snapshot, event: any Eventable, actor: InspectionActorRef, rootId: String
    ) -> InspectionEvent? { nil }

    /// The `@xstate.snapshot` event for a settled snapshot, or nil.
    func inspectionSnapshotEvent(
        _ snapshot: Snapshot, event: any Eventable, actor: InspectionActorRef, rootId: String
    ) -> InspectionEvent? { nil }

    func startupActionTypes(input: SendableValue?) -> [String] { [] }

    func stoppedSnapshot(_ snapshot: Snapshot) -> Snapshot { snapshot }

    func output(of snapshot: Snapshot) -> SendableValue? { nil }

    func childSnapshotValue(of snapshot: Snapshot) -> String? { nil }
}
