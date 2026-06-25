#if SWIFTXSTATE_APPLE_UI
import SwiftUI
import SwiftXState

/// A SwiftUI driver that hides actor latency with **optimistic, client-side prediction**.
///
/// `Actor<MachineLogic<Context>>` is a Swift `actor`, so every `send` is a round trip off the main actor and back
/// before SwiftUI can see the new snapshot. For latency-sensitive, high-frequency input (dragging to
/// draw, typing, dragging a slider) that round trip is visible as lag. This driver removes it for the
/// events you opt in to: it predicts their result *synchronously on the main actor* and publishes it
/// immediately, then lets the actor compute the authoritative result asynchronously and reconciles.
///
/// The prediction is **not** hand-written reducer logic — it reuses the machine's own pure
/// ``transition(_:snapshot:event:)``, so a predicted snapshot can never diverge from what the actor
/// will independently compute (side effects aside, which only ever run on the actor). That is the key
/// advantage over a bespoke optimistic mirror.
///
/// ### Reconciliation
/// The driver keeps the list of predicted events that have been sent but not yet confirmed by the
/// actor. The published `snapshot` is always `confirmed` with those still-pending predictions replayed
/// on top. When the actor confirms an event, that event is dropped and the remaining predictions are
/// replayed on the new authoritative snapshot. This is what prevents a late confirmation from
/// clobbering edits the user made *after* it during a fast drag — no per-event special-casing needed.
///
/// ### Opt in per event
/// Only predict events whose transition is **deterministic** and side-effect-free in its context
/// effect. Do *not* predict events that are non-deterministic (e.g. an assign using `random`) or whose
/// result depends on async work — the prediction would briefly disagree with the actor and the UI
/// would flicker on reconcile. `predict` defaults to predicting nothing, in which case this behaves
/// like a serialized `MachineDriver`.
///
/// ```swift
/// let driver = OptimisticMachineDriver(machine, actor: actor, snapshot: snap) { event in
///     (event as? MyEvent).map { if case .draw = $0 { true } else { false } } ?? false
/// }
/// driver.send(.draw(x, y))   // grid repaints this runloop turn; actor catches up in the background
/// ```
@MainActor
@Observable
public final class OptimisticMachineDriver<Context: Sendable> {
    /// The snapshot the UI should render: `confirmed` with all still-in-flight predicted events
    /// replayed on top. Updates synchronously when you `send` a predicted event.
    public private(set) var snapshot: MachineSnapshot<Context>

    /// The most recent snapshot confirmed by the actor, with no unconfirmed predictions applied.
    public private(set) var confirmed: MachineSnapshot<Context>

    /// The underlying actor — the authority for state, side effects, children, and persistence.
    public let actor: Actor<MachineLogic<Context>>

    /// Called on the main actor after each event's authoritative snapshot has been applied, in send
    /// order. A hook for host-side bookkeeping (history, derived state) that must observe every event.
    @ObservationIgnored public var onTransition: (@MainActor (any Eventable) -> Void)?

    @ObservationIgnored private let machine: StateMachine<Context>
    @ObservationIgnored private let predict: @Sendable (any Eventable) -> Bool
    // Predicted events sent but not yet confirmed, in send order. The actor confirms in the same order
    // (sends are serialized on `chain`), so confirming a predicted event always drops the head.
    @ObservationIgnored private var pendingPredicted: [any Eventable] = []
    // Serializes actor interaction + reconciliation so confirmations are applied in send order.
    @ObservationIgnored private var chain: Task<Void, Never>?

    /// Adopts an **already-started** actor whose current snapshot is `snapshot`. Use this when you
    /// create or restore the actor yourself (e.g. hydrating from persistence) and just want the
    /// optimistic SwiftUI layer on top.
    public init(
        _ machine: StateMachine<Context>,
        actor: Actor<MachineLogic<Context>>,
        snapshot: MachineSnapshot<Context>,
        predict: @escaping @Sendable (any Eventable) -> Bool = { _ in false }
    ) {
        self.machine = machine
        self.actor = actor
        self.snapshot = snapshot
        self.confirmed = snapshot
        self.predict = predict
    }

    /// Creates and starts a fresh actor for `machine`, mirroring `MachineDriver`. The published
    /// snapshot is seeded synchronously from the machine's initial transition and replaced by the
    /// actor's post-start snapshot once it has started.
    public convenience init(
        _ machine: StateMachine<Context>,
        input: SendableValue? = nil,
        context: Context? = nil,
        predict: @escaping @Sendable (any Eventable) -> Bool = { _ in false }
    ) {
        let actor = createActor(machine, input: input)
        let initial = initialTransition(machine, input: input, context: context).snapshot
        self.init(machine, actor: actor, snapshot: initial, predict: predict)
        enqueue { [weak self] in
            guard let self else { return }
            await self.actor.start(input: input, context: context)
            self.confirmed = await self.actor.snapshot
            self.snapshot = self.replay(on: self.confirmed)
        }
    }

    /// Sends an event. If `predict` returns `true` for it, the predicted snapshot is applied
    /// synchronously before returning, so the UI updates this runloop turn. The returned task
    /// completes once the actor has confirmed the event and `onTransition` has run — `await` its
    /// `.value` to throttle a driving loop (e.g. autoplay) to the actor's real throughput.
    @discardableResult
    public func send(_ event: any Eventable) -> Task<Void, Never> {
        // Decide once, here, whether this event is predicted. Reusing the same value when the actor
        // confirms keeps the append (here) and the drop (below) in lockstep, so a `predict` that ever
        // returned inconsistently couldn't desync `pendingPredicted`.
        let wasPredicted = predict(event)
        if wasPredicted {
            pendingPredicted.append(event)
            snapshot = transition(machine, snapshot: snapshot, event: event).snapshot
        }
        return enqueue { [weak self] in
            guard let self else { return }
            await self.actor.send(event)
            self.confirmed = await self.actor.snapshot
            if wasPredicted, !self.pendingPredicted.isEmpty {
                self.pendingPredicted.removeFirst()
            }
            self.snapshot = self.replay(on: self.confirmed)
            self.onTransition?(event)
        }
    }

    /// Runs `work` on the driver's serialization chain, after all previously-sent events have been
    /// delivered to the actor. Use for actor-adjacent work that must observe the latest state, such as
    /// persisting a snapshot.
    @discardableResult
    public func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = chain
        let task = Task { @MainActor in
            _ = await previous?.value
            await work()
        }
        chain = task
        return task
    }

    /// Folds the still-pending predicted events over a base snapshot using the machine's pure
    /// transition, reproducing the optimistic state on top of a freshly confirmed snapshot.
    private func replay(on base: MachineSnapshot<Context>) -> MachineSnapshot<Context> {
        pendingPredicted.reduce(base) { acc, event in
            transition(machine, snapshot: acc, event: event).snapshot
        }
    }
}
#endif
