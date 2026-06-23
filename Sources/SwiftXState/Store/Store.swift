import Foundation

// MARK: - Store Types

/// A snapshot of store state at a point in time.
public struct StoreSnapshot<Context: Sendable>: Sendable, Equatable where Context: Equatable {
    public let context: Context
    public let status: StoreStatus

    public init(context: Context, status: StoreStatus = .active) {
        self.context = context
        self.status = status
    }
}

public enum StoreStatus: Sendable, Equatable {
    case active
    case stopped
}

/// Effects queued during a store transition, mirroring XState Store's `enqueue`.
public enum StoreQueuedEffect: Sendable {
    case sideEffect(@Sendable () -> Void)
    case emitted(EmittedEvent)
}

/// Result of a pure store transition.
public struct StoreTransitionResult<Context: Sendable & Equatable>: Sendable {
    public let snapshot: StoreSnapshot<Context>
    public let effects: [StoreQueuedEffect]

    public init(snapshot: StoreSnapshot<Context>, effects: [StoreQueuedEffect] = []) {
        self.snapshot = snapshot
        self.effects = effects
    }
}

/// Inspection events emitted by a store, aligned with XState Store's `.inspect`.
public struct StoreInspectionEvent<Context: Sendable & Equatable>: Sendable, Equatable {
    public let kind: InspectionEventKind
    public let snapshot: StoreSnapshot<Context>
    public let event: InspectionEventDescription?

    public init(
        kind: InspectionEventKind,
        snapshot: StoreSnapshot<Context>,
        event: InspectionEventDescription? = nil
    ) {
        self.kind = kind
        self.snapshot = snapshot
        self.event = event
    }
}

/// Enqueue handle passed to store assigners during a transition.
public final class StoreEnqueue<Context: Sendable & Equatable, E: Eventable>: @unchecked Sendable {
    private var effects: [StoreQueuedEffect] = []
    private var triggered: [E] = []
    private weak var store: Store<Context, E>?

    init(store: Store<Context, E>?) {
        self.store = store
    }

    /// Schedules a side effect to run after the transition commits.
    public func effect(_ work: @escaping @Sendable () -> Void) {
        effects.append(.sideEffect(work))
    }

    /// Schedules an emitted event for `store.on(…)` listeners.
    public func emit(_ event: EmittedEvent) {
        effects.append(.emitted(event))
    }

    /// Schedules another store event to be sent after the transition commits.
    public func trigger(_ event: E) {
        triggered.append(event)
    }

    fileprivate func drain(into result: inout [StoreQueuedEffect]) {
        result.append(contentsOf: effects)
        effects.removeAll()
    }

    fileprivate func takeTriggered() -> [E] {
        let pending = triggered
        triggered.removeAll()
        return pending
    }
}

/// A transition function for a store.
public typealias StoreTransition<Context: Sendable & Equatable, E: Eventable> = @Sendable (
    StoreSnapshot<Context>,
    E
) -> StoreSnapshot<Context>

/// Context assigner with optional rejection and enqueue support.
public typealias StoreAssigner<Context: Sendable & Equatable, E: Eventable> = @Sendable (
    Context,
    E,
    StoreEnqueue<Context, E>
) -> Context?

/// Legacy in-place context mutation handler.
public typealias StoreMutator<Context: Sendable & Equatable, E: Eventable> = @Sendable (
    inout Context,
    E
) -> Void

/// Configuration for creating a store.
public struct StoreConfig<Context: Sendable & Equatable, E: Eventable> {
    public var context: Context
    public var on: [String: StoreMutator<Context, E>]
    public var assign: [String: StoreAssigner<Context, E>]

    public init(
        context: Context,
        on: [String: StoreMutator<Context, E>] = [:],
        assign: [String: StoreAssigner<Context, E>] = [:]
    ) {
        self.context = context
        self.on = on
        self.assign = assign
    }
}

/// Reusable store definition, mirroring XState Store's `createStoreLogic`.
public struct StoreLogic<Context: Sendable & Equatable, E: Eventable>: Sendable {
    private let resolveConfig: @Sendable (SendableValue?) -> StoreConfig<Context, E>

    public init(
        context: Context,
        on: [String: StoreMutator<Context, E>] = [:],
        assign: [String: StoreAssigner<Context, E>] = [:]
    ) {
        resolveConfig = { _ in
            StoreConfig(context: context, on: on, assign: assign)
        }
    }

    public init(
        context: @escaping @Sendable (SendableValue?) -> Context,
        on: [String: StoreMutator<Context, E>] = [:],
        assign: [String: StoreAssigner<Context, E>] = [:]
    ) {
        resolveConfig = { input in
            StoreConfig(context: context(input), on: on, assign: assign)
        }
    }

    public init(resolveConfig: @escaping @Sendable (SendableValue?) -> StoreConfig<Context, E>) {
        self.resolveConfig = resolveConfig
    }

    public func createStore(input: SendableValue? = nil) -> Store<Context, E> {
        Store(resolveConfig(input))
    }

    public func resolvedConfig(input: SendableValue? = nil) -> StoreConfig<Context, E> {
        resolveConfig(input)
    }
}

/// Shallow equality for store selectors (reference identity for class instances).
public func shallowEqual<T: Equatable>(_ lhs: T, _ rhs: T) -> Bool {
    switch (lhs as Any, rhs as Any) {
    case let (lhsObject as AnyObject, rhsObject as AnyObject):
        return lhsObject === rhsObject
    default:
        return lhs == rhs
    }
}

// MARK: - Store Selector

/// Selects and subscribes to a derived slice of store context.
public final class StoreSelector<
    Context: Sendable & Equatable,
    E: Eventable,
    T: Sendable & Equatable
>: @unchecked Sendable {
    private weak var store: Store<Context, E>?
    private let selector: (Context) -> T
    private let equals: (T, T) -> Bool
    private var observers: [(T) -> Void] = []
    private var snapshotSubscription: Subscription?
    private let lock = NSLock()

    init(
        store: Store<Context, E>,
        selector: @escaping (Context) -> T,
        equals: @escaping (T, T) -> Bool
    ) {
        self.store = store
        self.selector = selector
        self.equals = equals
        self.snapshotSubscription = store.subscribe { [weak self] snapshot in
            self?.handleSnapshot(snapshot)
        }
    }

    public func get() -> T {
        guard let store else {
            fatalError("Store deallocated")
        }
        return selector(store.context)
    }

    public func subscribe(_ handler: @escaping (T) -> Void) -> Subscription {
        lock.lock()
        let value = get()
        handler(value)
        observers.append(handler)
        let index = observers.count - 1
        lock.unlock()

        return Subscription { [weak self] in
            self?.lock.lock()
            if index < self?.observers.count ?? 0 {
                self?.observers.remove(at: index)
            }
            self?.lock.unlock()
        }
    }

    private var lastValue: T?

    private func handleSnapshot(_ snapshot: StoreSnapshot<Context>) {
        let next = selector(snapshot.context)
        lock.lock()
        if let lastValue, equals(lastValue, next) {
            lock.unlock()
            return
        }
        lastValue = next
        let currentObservers = observers
        lock.unlock()

        for observer in currentObservers {
            observer(next)
        }
    }
}

// MARK: - Store

/// A lightweight event-driven store, mirroring XState Store.
public final class Store<Context: Sendable, E: Eventable>: @unchecked Sendable where Context: Equatable {
    private var _snapshot: StoreSnapshot<Context>
    private let initialSnapshotValue: StoreSnapshot<Context>
    private var observers: [(StoreSnapshot<Context>) -> Void] = []
    private let mutators: [String: StoreMutator<Context, E>]
    private let assigners: [String: StoreAssigner<Context, E>]
    private let emitListeners = EmitListeners()
    private var inspectors: [(StoreInspectionEvent<Context>) -> Void] = []
    private let lock = NSLock()

    public init(_ config: StoreConfig<Context, E>) {
        self._snapshot = StoreSnapshot(context: config.context)
        self.initialSnapshotValue = StoreSnapshot(context: config.context)
        self.mutators = config.on
        self.assigners = config.assign
    }

    /// The current store snapshot.
    public var snapshot: StoreSnapshot<Context> {
        getSnapshot()
    }

    /// Mirrors XState Store's `getSnapshot()`.
    public func getSnapshot() -> StoreSnapshot<Context> {
        lock.lock()
        defer { lock.unlock() }
        return _snapshot
    }

    /// Mirrors XState Store's `getInitialSnapshot()`.
    public func getInitialSnapshot() -> StoreSnapshot<Context> {
        initialSnapshotValue
    }

    /// The current context (convenience accessor).
    public var context: Context {
        snapshot.context
    }

    /// Sends an event to the store.
    public func send(_ event: E) {
        process(event, depth: 0)
    }

    /// Whether the store would accept an event without mutating state.
    public func can(_ event: E) -> Bool {
        let enqueue = StoreEnqueue<Context, E>(store: nil)
        return runTransition(from: getSnapshot(), event: event, enqueue: enqueue) != nil
    }

    /// Stops the store; further events are ignored.
    public func stop() {
        lock.lock()
        guard _snapshot.status == .active else {
            lock.unlock()
            return
        }
        _snapshot = StoreSnapshot(context: _snapshot.context, status: .stopped)
        let stoppedSnapshot = _snapshot
        lock.unlock()

        notify(stoppedSnapshot)
        notifyInspectors(StoreInspectionEvent(kind: .snapshot, snapshot: stoppedSnapshot))
        emitListeners.removeAll()
    }

    /// Computes the next snapshot without mutating the store.
    public func transition(_ snapshot: StoreSnapshot<Context>, event: E) -> StoreSnapshot<Context> {
        transitionResult(snapshot, event: event).snapshot
    }

    /// Pure transition including queued effects, mirroring XState Store's tuple result.
    public func transitionResult(
        _ snapshot: StoreSnapshot<Context>,
        event: E
    ) -> StoreTransitionResult<Context> {
        let enqueue = StoreEnqueue<Context, E>(store: nil)
        return runTransition(from: snapshot, event: event, enqueue: enqueue)
            ?? StoreTransitionResult(snapshot: snapshot)
    }

    /// Subscribe to snapshot changes.
    public func subscribe(_ handler: @escaping (StoreSnapshot<Context>) -> Void) -> Subscription {
        lock.lock()
        handler(_snapshot)
        observers.append(handler)
        let index = observers.count - 1
        lock.unlock()

        return Subscription { [weak self] in
            self?.lock.lock()
            defer { self?.lock.unlock() }
            if index < self?.observers.count ?? 0 {
                self?.observers.remove(at: index)
            }
        }
    }

    /// Listen for emitted events, mirroring XState Store's `store.on(…)`.
    public func on(
        _ eventType: String,
        handler: @escaping @Sendable (EmittedEvent) -> Void
    ) -> Subscription {
        emitListeners.on(eventType, handler: handler)
    }

    /// Inspect store snapshots and transitions.
    public func inspect(
        _ handler: @escaping (StoreInspectionEvent<Context>) -> Void
    ) -> Subscription {
        lock.lock()
        handler(StoreInspectionEvent(kind: .snapshot, snapshot: _snapshot))
        inspectors.append(handler)
        let index = inspectors.count - 1
        lock.unlock()

        return Subscription { [weak self] in
            self?.lock.lock()
            defer { self?.lock.unlock() }
            if index < self?.inspectors.count ?? 0 {
                self?.inspectors.remove(at: index)
            }
        }
    }

    /// Creates a selector for a derived slice of context.
    public func select<T: Sendable & Equatable>(
        _ selector: @escaping (Context) -> T,
        equals: @escaping (T, T) -> Bool = { $0 == $1 }
    ) -> StoreSelector<Context, E, T> {
        StoreSelector(store: self, selector: selector, equals: equals)
    }

    private func process(_ event: E, depth: Int) {
        guard depth < 64 else { return }

        lock.lock()
        guard _snapshot.status == .active else {
            lock.unlock()
            return
        }
        let before = _snapshot
        lock.unlock()

        let enqueue = StoreEnqueue<Context, E>(store: self)
        guard let result = runTransition(from: before, event: event, enqueue: enqueue) else {
            return
        }

        lock.lock()
        _snapshot = result.snapshot
        let after = _snapshot
        lock.unlock()

        notify(after)
        notifyInspectors(
            StoreInspectionEvent(
                kind: .transition,
                snapshot: after,
                event: .describe(event)
            )
        )
        flushEffects(result.effects)

        var pending = enqueue.takeTriggered()
        while let next = pending.first {
            pending.removeFirst()
            process(next, depth: depth + 1)
            pending.append(contentsOf: enqueue.takeTriggered())
        }
    }

    private func runTransition(
        from snapshot: StoreSnapshot<Context>,
        event: E,
        enqueue: StoreEnqueue<Context, E>
    ) -> StoreTransitionResult<Context>? {
        var effects: [StoreQueuedEffect] = []
        var nextContext = snapshot.context

        if let assigner = assigners[event.type] {
            guard let assigned = assigner(snapshot.context, event, enqueue) else {
                return nil
            }
            nextContext = assigned
        } else if var context = Optional(snapshot.context), let mutator = mutators[event.type] {
            mutator(&context, event)
            nextContext = context
        }

        enqueue.drain(into: &effects)

        let nextSnapshot = StoreSnapshot(context: nextContext, status: snapshot.status)
        return StoreTransitionResult(snapshot: nextSnapshot, effects: effects)
    }

    private func flushEffects(_ effects: [StoreQueuedEffect]) {
        for effect in effects {
            switch effect {
            case let .sideEffect(work):
                work()
            case let .emitted(event):
                emitListeners.notify(event)
            }
        }
    }

    private func notify(_ snapshot: StoreSnapshot<Context>) {
        lock.lock()
        let current = observers
        lock.unlock()
        for observer in current {
            observer(snapshot)
        }
    }

    private func notifyInspectors(_ event: StoreInspectionEvent<Context>) {
        lock.lock()
        let current = inspectors
        lock.unlock()
        for inspector in current {
            inspector(event)
        }
    }
}

/// Creates a store from configuration.
public func createStore<Context: Sendable & Equatable, E: Eventable>(
    context: Context,
    on: [String: StoreMutator<Context, E>] = [:],
    assign: [String: StoreAssigner<Context, E>] = [:]
) -> Store<Context, E> {
    Store(StoreConfig(context: context, on: on, assign: assign))
}

/// Creates reusable store logic.
public func createStoreLogic<Context: Sendable & Equatable, E: Eventable>(
    context: Context,
    on: [String: StoreMutator<Context, E>] = [:],
    assign: [String: StoreAssigner<Context, E>] = [:]
) -> StoreLogic<Context, E> {
    StoreLogic(context: context, on: on, assign: assign)
}

/// Creates reusable store logic with input-derived context.
public func createStoreLogic<Context: Sendable & Equatable, E: Eventable>(
    context: @escaping @Sendable (SendableValue?) -> Context,
    on: [String: StoreMutator<Context, E>] = [:],
    assign: [String: StoreAssigner<Context, E>] = [:]
) -> StoreLogic<Context, E> {
    StoreLogic(context: context, on: on, assign: assign)
}

// MARK: - Store from transition function

/// Creates a store from a single transition function.
public func createStore<Context: Sendable & Equatable, E: Eventable>(
    context: Context,
    transition transitionFn: @escaping @Sendable (StoreSnapshot<Context>, E) -> StoreSnapshot<Context>
) -> TransitionFunctionStore<Context, E> {
    TransitionFunctionStore(context: context, transition: transitionFn)
}

/// Store backed by a single transition function.
public final class TransitionFunctionStore<Context: Sendable & Equatable, E: Eventable>: @unchecked Sendable {
    private var _snapshot: StoreSnapshot<Context>
    private let initialSnapshotValue: StoreSnapshot<Context>
    private var observers: [(StoreSnapshot<Context>) -> Void] = []
    private let transitionFn: @Sendable (StoreSnapshot<Context>, E) -> StoreSnapshot<Context>
    private let lock = NSLock()

    public init(
        context: Context,
        transition: @escaping @Sendable (StoreSnapshot<Context>, E) -> StoreSnapshot<Context>
    ) {
        self._snapshot = StoreSnapshot(context: context)
        self.initialSnapshotValue = StoreSnapshot(context: context)
        self.transitionFn = transition
    }

    public var snapshot: StoreSnapshot<Context> {
        getSnapshot()
    }

    public func getSnapshot() -> StoreSnapshot<Context> {
        lock.lock()
        defer { lock.unlock() }
        return _snapshot
    }

    public func getInitialSnapshot() -> StoreSnapshot<Context> {
        initialSnapshotValue
    }

    public var context: Context { snapshot.context }

    public func send(_ event: E) {
        lock.lock()
        defer { lock.unlock() }
        guard _snapshot.status == .active else { return }
        _snapshot = transitionFn(_snapshot, event)
        notify(_snapshot)
    }

    public func can(_ event: E) -> Bool {
        let current = getSnapshot()
        return transitionFn(current, event) != current
    }

    public func stop() {
        lock.lock()
        guard _snapshot.status == .active else {
            lock.unlock()
            return
        }
        _snapshot = StoreSnapshot(context: _snapshot.context, status: .stopped)
        let stopped = _snapshot
        lock.unlock()
        notify(stopped)
    }

    public func transition(_ snapshot: StoreSnapshot<Context>, event: E) -> StoreSnapshot<Context> {
        transitionFn(snapshot, event)
    }

    public func subscribe(_ handler: @escaping (StoreSnapshot<Context>) -> Void) -> Subscription {
        lock.lock()
        handler(_snapshot)
        observers.append(handler)
        let index = observers.count - 1
        lock.unlock()

        return Subscription { [weak self] in
            self?.lock.lock()
            defer { self?.lock.unlock() }
            if index < self?.observers.count ?? 0 {
                self?.observers.remove(at: index)
            }
        }
    }

    private func notify(_ snapshot: StoreSnapshot<Context>) {
        for observer in observers {
            observer(snapshot)
        }
    }
}