// Reactive atoms are the port of XState v6's @xstate/store. They are excluded from Embedded
// Swift: the dependency graph relies on weak references (prohibited in Embedded) to let a
// computed atom observe atoms that may go away, and the engine is additive rather than core
// statechart machinery. Everything else in SwiftXState works without it.
#if !hasFeature(Embedded)


import Synchronization

// MARK: - Public surface

/// A reactive value you can read and observe. Both the writable ``Atom`` and the derived
/// ``ComputedAtom`` conform. This is the Swift port of the readable half of XState v6's
/// `@xstate/store` atom — a standalone reactive cell, usable with or without a machine.
///
/// Reading ``value`` inside a ``ComputedAtom``'s compute closure records a dependency, so the
/// computed automatically re-derives when that value changes.
public protocol ReadableAtom<Value>: AnyObject, Sendable {
    associatedtype Value: Sendable

    /// The current value.
    var value: Value { get }

    /// Observe changes. Fires **immediately** with the current value (BehaviorSubject semantics,
    /// matching ``Store`` / ``Actor`` `subscribe`), then on every subsequent change that differs per
    /// the atom's `compare`. Call `cancel()` on the returned ``Subscription`` to stop.
    @discardableResult
    func subscribe(_ handler: @escaping @Sendable (Value) -> Void) -> Subscription
}

// MARK: - Engine internals

/// The single gate guarding the whole atom dependency graph, built on `Synchronization.Mutex`.
///
/// ## Why one *global* lock — yes, on purpose
///
/// A process-global lock (and the global mutable graph state it guards) trips every "this is an
/// antipattern" alarm. It is deliberate, and it is the cheapest *correct* option. The reasoning,
/// since it is genuinely not obvious:
///
/// **What it protects is the graph, not an atom.** Glitch-free propagation means one write must
/// atomically mark *every* transitive computed dependent stale before any observer can read (see
/// `markStaleAndCollectObserved`). That critical section inherently spans many atoms at once — it is
/// not per-atom state, so a per-atom lock cannot even express the invariant.
///
/// **Per-atom locks would be worse, not better.** A write walks *downstream*, touching each dependent
/// to mark it stale; a computed's read walks *upstream*, touching each source to register a dependency
/// edge. Those two walks would take the same per-atom locks in opposite orders → textbook ABBA
/// deadlock, avoidable only with a global lock-ordering protocol over the entire graph — and you'd be
/// holding a *chain* of locks across each walk, strictly more contention than one gate buys. One gate
/// means graph walks touch no lock ordering at all, so there is no ABBA hazard to reason about.
///
/// **It is cheap because of what it does *not* hold.** The gate covers only O(graph-bookkeeping)
/// pointer work: compare, swap a field, walk the dependent set, snapshot the observer list. It is
/// *never* held across a `compute` closure or an observer callback — those run with the gate released
/// (a callback that itself touches atoms just re-acquires it). An uncontended `Mutex` on Darwin is
/// `os_unfair_lock`-class — a compare-exchange, no syscall — so when nothing actually contends (the
/// common case) "global" costs a handful of nanoseconds. The lock's *reach* (every atom) is not its
/// *cost* (nanoseconds of uncontended bookkeeping); conflating the two is the reflex to resist here.
///
/// **Where it genuinely serializes.** Two *independent* atom graphs written concurrently from
/// different threads do contend on this gate despite sharing no data. That is a non-issue under the
/// intended usage — each graph driven from one view model or one `Actor`, i.e. XState's single-
/// writer-per-domain model, where a graph's writes are already serialized upstream of this lock. If a
/// real workload ever shows cross-graph gate contention in a profile, the fix is to partition the gate
/// *per store* (one lock per graph). It is global today only because `createAtom` yields free-floating
/// atoms with no owning store object to scope a lock to, and a computed may read atoms from anywhere.
/// JS XState dodges the whole question by being single-threaded; this gate is the price of making it
/// thread-safe in Swift at all.
///
/// ## "But is the *locking discipline itself* racy?"
///
/// The mutex cannot race. But because it is **non-reentrant** (a `Mutex` is not recursive) it must be
/// *released* across every `compute()` and every delivery — which does open deliberate check-then-act
/// windows: state is read under one acquisition and acted on under a later one. Those windows are not
/// bugs; they are closed by two explicit mechanisms, and **any change here must preserve them**:
///   - `ComputedAtom.dirtyVersion` — if a source changes *during* a recompute, the value just produced
///     may already be stale, so the node stays `dirty` instead of clearing over a lost invalidation
///     (`settledValue`).
///   - `deliveryGen` — a delivery a newer write has already superseded is dropped, coalescing
///     redundant / out-of-order notifications so observers converge on the settled value.
///
/// Uses the house `Mutex(false)` + `lock()/unlock()` idiom (`Util/Mutex+Locking`) precisely because
/// these critical sections must temporarily release the gate.
private let gate = Mutex(false)

/// Lock-free source of monotonic observer ids.
private let observerIDSource = Atomic<Int>(0)

/// The computed atom currently (re)evaluating on this task, with a per-invocation dependency
/// collector. Task-local so concurrent evaluations never share collection state.
private final class EvaluationContext: @unchecked Sendable {
    // Per-evaluation; `collected` is appended only under `gate` during a single synchronous compute,
    // so it is never touched concurrently despite the @TaskLocal Sendable requirement.
    let node: any AtomNode
    var collected: [any AtomNode] = []
    init(_ node: any AtomNode) { self.node = node }
}
private enum Evaluation {
    @TaskLocal static var context: EvaluationContext?
    /// The computeds currently on *this task's* evaluation stack — for cycle detection that doesn't
    /// false-trip on legitimate concurrent recompute of the same node from another task.
    @TaskLocal static var evaluating: Set<ObjectIdentifier> = []
}

private struct WeakAtomNode { weak var node: (any AtomNode)? }

/// A node in the dependency graph — a writable ``Atom`` or a ``ComputedAtom``. Internal so the public
/// atom types stay `public` while sharing the (non-public) graph machinery via conformance. Every
/// method here is invoked **under `gate`** unless noted.
private protocol AtomNode: AnyObject, Sendable {
    var nodeID: ObjectIdentifier { get }
    var dependentSet: DependentSet { get }
    func invalidate()                         // an upstream dependency changed → become stale
    func hasObservers() -> Bool
    /// Settle this node's value (recomputing if needed, *outside* the gate) and, if it changed since
    /// its observers last saw it, fire them. Manages its own gate acquisition; callers invoke it with
    /// the gate **released**.
    func deliverIfChanged()
}

extension AtomNode {
    var nodeID: ObjectIdentifier { ObjectIdentifier(self) }
    func invalidate() {}
    func hasObservers() -> Bool { false }
}

/// The set of computed nodes that read a given node. Weakly held: a computed stays alive through its
/// owner / subscribers, never through the atoms it reads. Accessed under `gate`.
private final class DependentSet {
    private var dependents: [ObjectIdentifier: WeakAtomNode] = [:]
    func add(_ node: any AtomNode) { dependents[node.nodeID] = WeakAtomNode(node: node) }
    func remove(_ id: ObjectIdentifier) { dependents[id] = nil }
    func live() -> [any AtomNode] {
        var result: [any AtomNode] = []
        for (id, box) in dependents {
            if let node = box.node { result.append(node) } else { dependents[id] = nil }
        }
        return result
    }
}

/// Under `gate`: mark every downstream computed stale and collect the nodes that have observers (they
/// will be settled + compared to decide whether to notify). Each node is visited once, so diamonds
/// don't re-mark or re-collect.
private func markStaleAndCollectObserved(from origin: any AtomNode) -> [any AtomNode] {
    var observed: [any AtomNode] = []
    var visited = Set<ObjectIdentifier>()
    func walk(_ node: any AtomNode, invalidate: Bool) {
        guard visited.insert(node.nodeID).inserted else { return }
        if invalidate { node.invalidate() }
        if node.hasObservers() { observed.append(node) }
        for dependent in node.dependentSet.live() { walk(dependent, invalidate: true) }
    }
    walk(origin, invalidate: false)   // origin's own value was already committed by the caller
    return observed
}

/// Under `gate`: register `source` as a dependency of whatever computed is currently evaluating.
private func linkToCurrentEvaluation(_ source: any AtomNode) {
    guard let ctx = Evaluation.context, ctx.node.nodeID != source.nodeID else { return }
    source.dependentSet.add(ctx.node)
    ctx.collected.append(source)
}

// MARK: - Writable atom

/// A **writable** reactive cell. Assign ``value`` to update it and notify observers / re-derive
/// dependents. Mirrors XState v6 `createAtom(initialValue)`.
///
/// Data-race-free: read, write, and subscribe from any thread. Under *concurrent writers to the same
/// atom* delivery is best-effort — intermediate values may coalesce and the last delivered value may
/// briefly lag — but once writes quiesce an established subscriber converges to the settled value.
/// Write each atom from a single domain (a view model / an ``Actor``) for fully ordered, complete
/// delivery, matching XState's single-threaded model.
public final class Atom<Value: Sendable>: AtomNode, ReadableAtom, @unchecked Sendable {
    fileprivate let dependentSet = DependentSet()
    private var snapshot: Value
    private var lastEmitted: Value?
    private let compare: @Sendable (Value, Value) -> Bool
    private var observers: [Int: @Sendable (Value) -> Void] = [:]
    private let deliveryGen = Atomic<Int>(0)

    /// Creates a writable atom with a custom equality used to suppress no-op updates/notifications.
    /// `compare` runs under the internal lock, so — like a `compute` closure — it must be pure and must
    /// not read or write any atom.
    public init(_ initialValue: Value, compare: @escaping @Sendable (Value, Value) -> Bool) {
        self.snapshot = initialValue
        self.compare = compare
    }

    public var value: Value {
        get {
            gate.lock(); defer { gate.unlock() }
            linkToCurrentEvaluation(self)
            return snapshot
        }
        set { deliver(commit(newValue)) }
    }

    /// Atomically update via a function of the current value (`atom.update { $0 + 1 }`) — the read and
    /// write happen under one gate acquisition, so concurrent updates don't lose each other.
    public func update(_ transform: (Value) -> Value) {
        gate.lock()
        let next = transform(snapshot)
        let observed = commitLocked(next)
        gate.unlock()
        deliver(observed)
    }

    private func commit(_ newValue: Value) -> [any AtomNode] {
        gate.lock(); defer { gate.unlock() }
        return commitLocked(newValue)
    }

    /// Commit `newValue` and return the downstream observed nodes to settle. Caller holds `gate`.
    private func commitLocked(_ newValue: Value) -> [any AtomNode] {
        guard !compare(snapshot, newValue) else { return [] }
        snapshot = newValue
        return markStaleAndCollectObserved(from: self)
    }

    private func deliver(_ observed: [any AtomNode]) {
        for node in observed { node.deliverIfChanged() }   // outside the gate
    }

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (Value) -> Void) -> Subscription {
        let id = observerIDSource.wrappingAdd(1, ordering: .relaxed).oldValue
        gate.lock()
        observers[id] = handler
        lastEmitted = snapshot
        let current = snapshot
        gate.unlock()
        handler(current)                                       // BehaviorSubject: fire immediately
        // Strong `self`: holding the Subscription keeps the atom (and its dependency chain) alive,
        // AnyCancellable-style. No retain cycle — the atom never references the Subscription.
        return Subscription { [self] in
            gate.lock(); observers[id] = nil; gate.unlock()
        }
    }

    fileprivate func hasObservers() -> Bool { !observers.isEmpty }

    fileprivate func deliverIfChanged() {
        gate.lock()
        let value = snapshot
        if let last = lastEmitted, compare(last, value) { gate.unlock(); return }
        lastEmitted = value
        let myGen = deliveryGen.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
        let handlers = Array(observers.values)
        gate.unlock()
        // Drop a delivery a newer write has already superseded — coalesces redundant/out-of-order
        // notifications under contention (best-effort; a final uncontended write settles observers).
        guard deliveryGen.load(ordering: .acquiring) == myGen else { return }
        for handler in handlers { handler(value) }
    }
}

public extension Atom where Value: Equatable {
    /// Creates a writable atom that treats `==`-equal values as no-ops.
    convenience init(_ initialValue: Value) { self.init(initialValue, compare: { @Sendable in $0 == $1 }) }
}

// MARK: - Computed atom

/// A **read-only** atom whose value is derived from other atoms. Any atom read inside `compute` is
/// tracked automatically, so the computed re-derives when a source changes. Recomputation is lazy
/// (on read) and memoized (once per change), and observers see the settled value — no diamond glitch.
/// Mirrors XState v6 `createAtom(getter)`.
///
/// `compute` must be **pure** — no side effects, and it must not read or write any atom outside its
/// own dependency reads — and it must read every dependency **synchronously on the calling thread**:
/// an atom read from a spawned `Task` or a different thread is not tracked (so the computed would
/// never invalidate for it). Cyclic dependencies between computed atoms are a programmer error and
/// trap. A computed whose *dependency set changes between evaluations* (a branch-selecting `compute`)
/// may, under concurrent recompute, transiently drop a dependency edge and read stale until the next
/// write; own such an atom from a single domain (an ``Actor``) to avoid it.
public final class ComputedAtom<Value: Sendable>: AtomNode, ReadableAtom, @unchecked Sendable {
    fileprivate let dependentSet = DependentSet()
    private let compute: @Sendable () -> Value
    private let compare: @Sendable (Value, Value) -> Bool
    private var snapshot: Value?                               // nil until first evaluation
    private var lastEmitted: Value?
    private var dirty = true
    private var dirtyVersion = 0                               // bumped on each invalidation
    private var dependencies: [ObjectIdentifier: any AtomNode] = [:]
    private var observers: [Int: @Sendable (Value) -> Void] = [:]
    private let deliveryGen = Atomic<Int>(0)

    public init(compare: @escaping @Sendable (Value, Value) -> Bool, _ compute: @escaping @Sendable () -> Value) {
        self.compute = compute
        self.compare = compare
    }

    public var value: Value {
        let settled = settledValue()               // recompute (outside gate) if stale
        gate.lock(); linkToCurrentEvaluation(self); gate.unlock()
        return settled
    }

    /// The current value, recomputing outside the gate if stale. The `compute` closure runs with the
    /// gate released; the sources it reads each re-acquire the gate briefly to register themselves.
    private func settledValue() -> Value {
        gate.lock()
        if !dirty, let snapshot { gate.unlock(); return snapshot }
        let previous = dependencies
        let startVersion = dirtyVersion
        gate.unlock()

        if Evaluation.evaluating.contains(nodeID) {
            fatalError("Circular atom dependency detected in a ComputedAtom.")
        }
        let ctx = EvaluationContext(self)
        let result = Evaluation.$evaluating.withValue(Evaluation.evaluating.union([nodeID])) {
            Evaluation.$context.withValue(ctx) { compute() }
        }

        gate.lock()
        var next: [ObjectIdentifier: any AtomNode] = [:]
        for source in ctx.collected { next[source.nodeID] = source }
        for (id, source) in previous where next[id] == nil { source.dependentSet.remove(nodeID) }
        dependencies = next
        snapshot = result
        // If a source changed *during* this compute, the value we just produced may already be stale —
        // stay dirty so the next read recomputes, rather than clearing dirty over a lost invalidation.
        dirty = dirtyVersion != startVersion
        gate.unlock()
        return result
    }

    @discardableResult
    public func subscribe(_ handler: @escaping @Sendable (Value) -> Void) -> Subscription {
        _ = settledValue()                          // establish dependencies + ensure computed
        let id = observerIDSource.wrappingAdd(1, ordering: .relaxed).oldValue
        gate.lock()
        observers[id] = handler
        let current = snapshot!                      // read under the gate, consistent with lastEmitted
        lastEmitted = current
        gate.unlock()
        handler(current)                            // BehaviorSubject: fire immediately
        // Strong `self`: holding the Subscription keeps this computed (and, via its `dependencies`,
        // its sources) alive for as long as you observe it. No cycle.
        return Subscription { [self] in
            gate.lock(); observers[id] = nil; gate.unlock()
        }
    }

    fileprivate func invalidate() { dirty = true; dirtyVersion &+= 1 }
    fileprivate func hasObservers() -> Bool { !observers.isEmpty }

    fileprivate func deliverIfChanged() {
        _ = settledValue()                          // ensure settled (recompute if stale)
        gate.lock()
        // Read the value under the SAME gate hold as the generation bump, so value-freshness stays
        // monotonic with the generation — exactly as the writable `Atom` does. (Reading a value
        // captured *before* the gate would let a stale-value deliverer win a higher generation and
        // fire last.) If a concurrent write left us dirty again, skip: that write's own delivery
        // fires the fresh value.
        guard !dirty, let value = snapshot else { gate.unlock(); return }
        if let last = lastEmitted, compare(last, value) { gate.unlock(); return }
        lastEmitted = value
        let myGen = deliveryGen.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
        let handlers = Array(observers.values)
        gate.unlock()
        guard deliveryGen.load(ordering: .acquiring) == myGen else { return }
        for handler in handlers { handler(value) }
    }
}

public extension ComputedAtom where Value: Equatable {
    /// Creates a derived atom that treats `==`-equal derived values as no-ops.
    convenience init(_ compute: @escaping @Sendable () -> Value) { self.init(compare: { @Sendable in $0 == $1 } , compute) }
}

// MARK: - XState-parity factories

/// Creates a **writable** atom — the Swift equivalent of XState v6 `createAtom(initialValue)`.
public func createAtom<Value: Sendable & Equatable>(_ initialValue: Value) -> Atom<Value> {
    Atom(initialValue)
}

/// Creates a **computed** read-only atom — the Swift equivalent of XState v6 `createAtom(getter)`.
public func createAtom<Value: Sendable & Equatable>(_ compute: @escaping @Sendable () -> Value) -> ComputedAtom<Value> {
    ComputedAtom(compute)
}

#endif // !hasFeature(Embedded)
