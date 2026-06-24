import Foundation

/// **Experimental — generics refactor.** The generic actor *core*: a mailbox + run-to-completion
/// loop + observers, parameterized purely by an `ActorLogic`. It owns no machine concepts — it just
/// folds events into snapshots via `logic.step` and notifies subscribers. This is the
/// Context-agnostic skeleton that `StateActor` will eventually be expressed in terms of (the machine
/// orchestration — effects / `after` / `invoke` — layering on top as a capability over the resources
/// it would additionally own).
///
/// Proven today to host two distinct logic kinds with one implementation: a hand-written reducer,
/// and `MachineLogic` for any effect-free machine (transitions / `always` / `assign` / guards /
/// parallel / history). See `LogicActorTests`.
actor LogicActor<L: ActorLogic> {
    private let logic: L
    private var _snapshot: L.Snapshot?
    private var mailbox: [any Eventable] = []
    private var isProcessing = false
    private var observers: [(id: Int, handler: @Sendable (L.Snapshot) -> Void)] = []
    private var nextObserverID = 0

    nonisolated let id: String

    init(_ logic: L, id: String = UUID().uuidString) {
        self.logic = logic
        self.id = id
    }

    /// The current snapshot. Traps if the actor hasn't been started.
    var snapshot: L.Snapshot {
        guard let snapshot = _snapshot else {
            fatalError("LogicActor has not been started. Call start() first.")
        }
        return snapshot
    }

    var status: SnapshotStatus {
        guard let snapshot = _snapshot else { return .stopped }
        return logic.status(of: snapshot)
    }

    @discardableResult
    func start(input: SendableValue? = nil) async -> Self {
        let snapshot = logic.initialState(input: input)
        _snapshot = snapshot
        notify(snapshot)
        return self
    }

    func send(_ event: any Eventable) async {
        mailbox.append(event)
        await drain()
    }

    @discardableResult
    func subscribe(_ handler: @escaping @Sendable (L.Snapshot) -> Void) -> Subscription {
        if let snapshot = _snapshot { handler(snapshot) }
        let id = nextObserverID
        nextObserverID += 1
        observers.append((id: id, handler: handler))
        return Subscription { [weak self] in
            Task { await self?.removeObserver(id: id) }
        }
    }

    private func removeObserver(id: Int) {
        observers.removeAll { $0.id == id }
    }

    private func drain() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        while !mailbox.isEmpty {
            await process(mailbox.removeFirst())
        }
    }

    private func process(_ event: any Eventable) async {
        guard let current = _snapshot, logic.status(of: current) == .active else { return }
        let next = logic.step(current, on: event)
        _snapshot = next
        notify(next)
    }

    private func notify(_ snapshot: L.Snapshot) {
        for observer in observers {
            observer.handler(snapshot)
        }
    }
}
