import Testing
import Foundation
@testable import SwiftXState

/// Thread-safe recorder so `@Sendable` observer closures can accumulate emitted values.
private final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func record(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func inc() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite("Atoms — reactive primitive (Phase 1)")
struct AtomTests {

    // MARK: Writable atom

    @Test("read/write value")
    func writableReadWrite() {
        let a = Atom(1)
        #expect(a.value == 1)
        a.value = 42
        #expect(a.value == 42)
    }

    @Test("subscribe fires immediately, then on change")
    func subscribeBehaviorSubject() {
        let a = Atom(10)
        let rec = Recorder<Int>()
        let sub = a.subscribe { rec.record($0) }
        #expect(rec.values == [10])                 // immediate (current value)
        a.value = 20
        a.value = 30
        #expect(rec.values == [10, 20, 30])
        sub.cancel()
        a.value = 40
        #expect(rec.values == [10, 20, 30])         // no more after cancel
    }

    @Test("equal writes are no-ops (compare dedups)")
    func compareDedups() {
        let a = Atom(1)
        let rec = Recorder<Int>()
        a.subscribe { rec.record($0) }
        a.value = 1                                  // equal → no notification
        #expect(rec.values == [1])
        a.value = 2
        a.value = 2                                  // equal → no second notification
        #expect(rec.values == [1, 2])
    }

    @Test("update is a read-modify-write")
    func functionalUpdate() {
        let a = Atom(0)
        a.update { $0 + 5 }
        a.update { $0 * 2 }
        #expect(a.value == 10)
    }

    @Test("custom compare")
    func customCompare() {
        // Only notify when the integer part changes.
        let a = Atom(1.0, compare: { Int($0) == Int($1) })
        let rec = Recorder<Double>()
        a.subscribe { rec.record($0) }
        a.value = 1.9                                // same int part → no notify
        #expect(rec.values == [1.0])
        a.value = 2.1                                // int part changed
        #expect(rec.values == [1.0, 2.1])
    }

    // MARK: Computed atom + automatic tracking

    @Test("computed derives and re-derives on source change")
    func computedDerives() {
        let a = Atom(2)
        let doubled = ComputedAtom { a.value * 2 }
        #expect(doubled.value == 4)
        a.value = 5
        #expect(doubled.value == 10)
    }

    @Test("computed tracks multiple sources automatically")
    func computedMultiSource() {
        let a = Atom(1)
        let b = Atom(2)
        let sum = ComputedAtom { a.value + b.value }
        let rec = Recorder<Int>()
        sum.subscribe { rec.record($0) }            // 3
        a.value = 10                                 // 12
        b.value = 20                                 // 30
        #expect(rec.values == [3, 12, 30])
    }

    @Test("computed is lazy and memoized")
    func lazyMemoized() {
        let a = Atom(1)
        let count = Counter()
        let c = ComputedAtom { count.inc(); return a.value * 2 }
        #expect(count.value == 0)                    // not computed until read
        #expect(c.value == 2); #expect(count.value == 1)
        #expect(c.value == 2); #expect(count.value == 1)  // memoized — no recompute
        a.value = 3                                   // dirty, but unobserved → not recomputed
        #expect(count.value == 1)
        #expect(c.value == 6); #expect(count.value == 2)  // recomputed on read
    }

    @Test("computed re-derive suppressed when result is unchanged")
    func computedCompareDedups() {
        let a = Atom(1)
        let isPositive = ComputedAtom { a.value > 0 }
        let rec = Recorder<Bool>()
        isPositive.subscribe { rec.record($0) }      // true
        a.value = 5                                   // still > 0 → derived value unchanged → no notify
        a.value = 100
        #expect(rec.values == [true])
        a.value = -1                                  // now false
        #expect(rec.values == [true, false])
    }

    @Test("chained computed (A → B → C)")
    func computedChain() {
        let a = Atom(1)
        let b = ComputedAtom { a.value + 1 }
        let c = ComputedAtom { b.value * 10 }
        let rec = Recorder<Int>()
        c.subscribe { rec.record($0) }               // (1+1)*10 = 20
        a.value = 4                                   // (4+1)*10 = 50
        #expect(rec.values == [20, 50])
    }

    @Test("dynamic dependencies: dep set changes with the branch taken")
    func dynamicDependencies() {
        let useA = Atom(true)
        let a = Atom(1)
        let b = Atom(2)
        let picked = ComputedAtom { useA.value ? a.value : b.value }
        let rec = Recorder<Int>()
        picked.subscribe { rec.record($0) }          // 1 (depends on useA, a — NOT b)
        b.value = 99                                  // not a dependency → no notify
        #expect(rec.values == [1])
        useA.value = false                            // now picks b → 99
        #expect(rec.values == [1, 99])
        a.value = 7                                   // a no longer a dependency → no notify
        #expect(rec.values == [1, 99])
        b.value = 3                                   // now b is a dependency → 3
        #expect(rec.values == [1, 99, 3])
    }

    // MARK: Glitch-free diamond

    @Test("diamond: one source change → one settled notification, no glitch")
    func diamondGlitchFree() {
        let s = Atom(1)
        let a = ComputedAtom { s.value * 10 }
        let b = ComputedAtom { s.value * 100 }
        let c = ComputedAtom { a.value + b.value }   // depends on both, both from s
        let rec = Recorder<Int>()
        c.subscribe { rec.record($0) }               // 1*10 + 1*100 = 110
        s.value = 2                                   // must be 2*10 + 2*100 = 220, exactly once
        #expect(rec.values == [110, 220])            // no intermediate glitch (e.g. 120 or 210)
    }

    // MARK: Subscriptions

    @Test("independent subscribers; cancelling one keeps the others")
    func multipleSubscribers() {
        let a = Atom(0)
        let r1 = Recorder<Int>(); let r2 = Recorder<Int>()
        let s1 = a.subscribe { r1.record($0) }
        a.subscribe { r2.record($0) }
        a.value = 1
        s1.cancel()
        a.value = 2
        #expect(r1.values == [0, 1])                 // stopped after cancel
        #expect(r2.values == [0, 1, 2])
    }

    // MARK: Factories

    @Test("createAtom factories mirror XState")
    func factories() {
        let writable = createAtom(3)
        writable.value = 4
        let computed = createAtom { writable.value + 1 }
        #expect(computed.value == 5)
    }

    // MARK: Concurrency

    @Test("concurrent update() is atomic")
    func concurrentAtomicUpdate() async {
        let a = Atom(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1000 {
                group.addTask { a.update { $0 + 1 } }
            }
        }
        #expect(a.value == 1000)
    }

    @Test("concurrent reads and writes stay consistent")
    func concurrentReadWrite() async {
        let a = Atom(0)
        let doubled = ComputedAtom { a.value * 2 }
        await withTaskGroup(of: Void.self) { group in
            for i in 1...200 {
                group.addTask { a.value = i }
                group.addTask { _ = doubled.value }
            }
        }
        // Final derived value is consistent with the final source value.
        #expect(doubled.value == a.value * 2)
    }

    @Test("an established subscriber converges to the settled value after concurrent writes")
    func concurrentDeliveryConverges() async {
        // Under concurrent writers delivery is best-effort, but once writes quiesce a final,
        // uncontended write settles the observer on the final value (no permanent staleness).
        let a = Atom(0)
        let rec = Recorder<Int>()
        a.subscribe { rec.record($0) }
        await withTaskGroup(of: Void.self) { group in
            for i in 1...500 { group.addTask { a.value = i } }
        }
        a.value = 1_000_000                           // final, uncontended
        #expect(a.value == 1_000_000)
        #expect(rec.values.last == 1_000_000)         // observer converged to the settled value
    }

    @Test("multi-source computed: subscriber converges to the settled value under two writers")
    func multiSourceComputedConverges() async {
        // A computed aggregating two *single-writer* atoms still has two threads delivering to it.
        // Delivery reads the value under the same lock hold as the generation, so no subscriber is
        // left on a stale sum once writes quiesce (regression for the decoupled-value delivery bug).
        let a = Atom(0)
        let b = Atom(0)
        let sum = ComputedAtom { a.value + b.value }
        let rec = Recorder<Int>()
        sum.subscribe { rec.record($0) }
        await withTaskGroup(of: Void.self) { group in
            for i in 1...300 {
                group.addTask { a.value = i }
                group.addTask { b.value = i }
            }
        }
        #expect(sum.value == a.value + b.value)
        #expect(rec.values.last == sum.value)         // subscriber converged, not left stale
    }

    @Test("holding the Subscription keeps a computed atom alive")
    func subscriptionRetainsAtom() {
        let a = Atom(1)
        let rec = Recorder<Int>()
        // The computed is not stored in a variable — only the Subscription anchors it.
        let sub = ComputedAtom { a.value * 10 }.subscribe { rec.record($0) }
        #expect(rec.values == [10])
        a.value = 5                                   // computed must still be alive and deliver
        #expect(rec.values == [10, 50])
        sub.cancel()
        a.value = 9
        #expect(rec.values == [10, 50])               // stopped after cancel
    }
}
