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

    public func stoppedSnapshot(_ snapshot: Snapshot) -> Snapshot { snapshot }

    public func output(of snapshot: Snapshot) -> SendableValue? { nil }

    public func childSnapshotValue(of snapshot: Snapshot) -> String? { nil }
}

/// A declarative side effect a logic asks the runtime to perform (modelled on XState v6's
/// `LogicEffect` — `emit` / `sendBack` / `raise`). `Actor` executes these through one serial
/// chain, so a child's outbound deliveries keep their order centrally — no per-child delivery chain,
/// and the historical `sendToParent`-before-`onDone` race can't recur.
enum LogicEffect: Sendable {
    /// Notify `on(_:)` emit listeners.
    case emit(EmittedEvent)
    /// Send an event up to the parent actor (XState's `sendBack`).
    case sendToParent(any Eventable)
    /// Deliver an event back to this actor (XState's `raise`).
    case deliverToSelf(any Eventable)
}

/// Handed to `ActorLogic.run` so a background driver (callback / task / observable child) can drive
/// its host actor: push snapshots (`update`), consume incoming events (`receive`), and produce
/// outbound effects (`sendToParent` / `emit`) — the latter routed through the host's ordered effect
/// chain. Mirrors XState v6's `CallbackLogicFunction` scope (`sendBack` / `receive` / `emit`).
public struct ActorScope<Snapshot: Sendable>: Sendable {
    /// This actor's id — so a logic can build child-targeted events (e.g. `SnapshotActorEvent`).
    public let actorId: String
    public let input: SendableValue?
    /// Push a new snapshot (dropped once the logic is no longer `.active`).
    public let update: @Sendable (Snapshot) async -> Void
    /// Register a handler for events sent to this actor.
    public let receive: @Sendable (@escaping @Sendable (any Eventable) -> Void) -> Void
    /// Send an event up to the parent (ordered).
    public let sendToParent: @Sendable (any Eventable) -> Void
    /// Notify emit listeners.
    public let emit: @Sendable (EmittedEvent) -> Void
    /// Mark the child done with an optional output — delivers a `DoneActorEvent` to the parent on the
    /// SAME ordered chain as `sendToParent` (so a just-sent event lands first) and sets `.done`.
    public let complete: @Sendable (SendableValue?) -> Void
    /// Mark the child errored — delivers an `ErrorActorEvent` (ordered) and sets `.error`.
    public let fail: @Sendable (String) -> Void
}

/// `MachineLogic` is an `ActorLogic`: its reducer *is* the macrostep. For an effect-free machine
/// this conformance is total — `Actor<MachineLogic<C>>` reaches the same snapshots as `Actor`.
/// For an effectful machine the `step` still computes the right *next snapshot*; what it omits is
/// the running of side effects / `after` / `invoke`, which `Actor` does not (yet) perform.
extension MachineLogic: ActorLogic {
    public func initialState(input: SendableValue?) -> MachineSnapshot<Context> {
        initialSnapshot(input: input, context: contextOverride).snapshot
    }

    public func step(_ snapshot: MachineSnapshot<Context>, on event: any Eventable) -> MachineSnapshot<Context> {
        reduce(snapshot, on: event).snapshot
    }

    public func status(of snapshot: MachineSnapshot<Context>) -> SnapshotStatus {
        snapshot.status
    }

    public func output(of snapshot: MachineSnapshot<Context>) -> SendableValue? { snapshot.output }

    public func childSnapshotValue(of snapshot: MachineSnapshot<Context>) -> String? { snapshot.value.description }

    public func stoppedSnapshot(_ snapshot: MachineSnapshot<Context>) -> MachineSnapshot<Context> {
        MachineSnapshot(
            machine: snapshot.machine,
            value: snapshot.value,
            context: snapshot.context,
            nodes: snapshot._nodes,
            tags: snapshot.tags,
            status: .stopped,
            historyValue: snapshot.historyValue,
            output: snapshot.output,
            error: snapshot.error,
            children: [:]
        )
    }
}
