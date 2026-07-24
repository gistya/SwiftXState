# Reactive Atoms

Standalone reactive values — writable cells and derived computeds — usable with or without a machine.

## Overview

An **atom** is a single reactive value you can read, write, and observe. It is SwiftXState's port of
XState v6's [`@xstate/store`](https://stately.ai/docs/xstate-store) `createAtom` — a lightweight
signal you can use entirely on its own, or wire into a machine so a transition fires when the atom
changes.

There are two kinds:

- A **writable** ``Atom`` — a cell you assign to. Mirrors `createAtom(initialValue)`.
- A **computed** ``ComputedAtom`` — a read-only value *derived* from other atoms, which re-derives
  automatically when any atom it read changes. Mirrors `createAtom(getter)`.

Both conform to ``ReadableAtom``, so anything that just *observes* a value can take either one.

> Note: Atoms are part of the core `SwiftXState` module and have **no** dependency on machines,
> actors, Foundation, or SwiftUI. They work on every platform the core supports (Apple, Linux,
> Windows, Wasm, Embedded).

## A writable atom

Create one with `createAtom` (or the ``Atom`` initializer), read it through ``Atom/value``,
and assign to update it:

```swift
let count = createAtom(0)          // Atom<Int>

count.value                        // 0
count.value = 1                    // update + notify observers

count.update { $0 + 1 }            // atomic read-modify-write → 2
```

Use ``Atom/update(_:)`` when the new value depends on the current one — the read and write happen
under one lock, so concurrent updates can't lose each other (unlike `count.value = count.value + 1`).

## Observing changes

``ReadableAtom/subscribe(_:)`` fires **immediately** with the current value (BehaviorSubject
semantics, matching ``Store`` and ``Actor``), then again on every change that differs per the atom's
`compare`. Hold onto the returned ``Subscription`` and ``Subscription/cancel()`` it to stop:

```swift
let sub = count.subscribe { value in
    print("count is now \(value)")   // fires right away with the current value, then on each change
}
// …later…
sub.cancel()
```

Holding the `Subscription` keeps the atom (and, for a computed, its whole dependency chain) alive —
`AnyCancellable`-style. Dropping it on the floor stops delivery.

## Computed atoms

A ``ComputedAtom`` derives its value from other atoms. Any atom you read **synchronously** inside the
`compute` closure is tracked as a dependency, so the computed re-derives when that atom changes — no
manual wiring:

```swift
let price    = createAtom(10)
let quantity = createAtom(2)

let total = createAtom { price.value * quantity.value }   // ComputedAtom<Int>
total.value          // 20

quantity.value = 3
total.value          // 30 — recomputed on read
```

Recomputation is **lazy** (it happens on the next read, not eagerly on every upstream write) and
**memoized** (once per change). Diamond-shaped graphs settle before observers fire, so a subscriber
never sees a half-updated "glitch" intermediate value.

> Important: A `compute` closure — and any custom `compare` — must be **pure**: no side effects, and
> it must not read or write any atom outside its own tracked dependency reads. It must also read every
> dependency **synchronously on the calling thread**; an atom read from a spawned `Task` or another
> thread is *not* tracked, so the computed would never re-derive for it. Cyclic dependencies between
> computeds are a programmer error and trap.

## Custom equality

By default an atom whose `Value` is `Equatable` treats `==`-equal values as no-ops (no notification).
Provide your own `compare` to change that — for example to compare only an id, or to always notify:

```swift
let user = Atom(User(id: 1, lastSeen: .distantPast)) { $0.id == $1.id }   // ignore lastSeen churn
let feed = Atom([Item](), compare: { _, _ in false })                     // always notify
```

## Driving a machine from an atom

Inside a transition you can subscribe the machine to an atom and relay a mapped event back into it
when the atom changes — `enq.subscribeTo(atom)`, the port of XState v6's `enq.subscribeTo(atom)`. It
fires with the atom's current value first, and the subscription is torn down automatically when the
actor stops:

```swift
enum PS: String, StateIdentifying { case idle, watching, exceeded; static var _blank: PS { .idle } }
enum PE: String, EventIdentifying { case start, over; static var _blank: PE { .start } }

struct Watcher: StateMachine {
    typealias Context = Int; typealias StateID = PS; typealias EventID = PE
    let threshold: Atom<Int>
    var context: Int { 0 }
    var machine: some XStateMachine {
        let threshold = self.threshold
        XState(.idle) {
            XTransition(on: .start, to: .watching).action { _, enq in
                enq.subscribeTo(threshold) { $0 > 10 ? .over : nil }   // nil drops the value
                return 0
            }
        }.initial()
        XState(.watching) { XTransition(on: .over, to: .exceeded) }
        XState(.exceeded) {}
    }
}
```

When `threshold.value` crosses 10, the mapped `.over` event is enqueued and the machine advances to
`exceeded`. In the string/config API the same effect is available as the ``subscribeToAtom(_:map:)``
action.

## Thread safety

Atoms are data-race-free: read, write, and subscribe from any thread. The whole atom graph is guarded
by one internal lock that is held only for bookkeeping — never across your `compute` closure or an
observer callback. Under *concurrent writers to the same atom*, delivery is best-effort: intermediate
values may coalesce and the last delivered value may briefly lag, but once writes quiesce an
established subscriber converges on the settled value. For fully ordered, complete delivery, write each
atom from a single domain (a view model or an ``Actor``) — the same single-writer model XState uses.

## Topics

### Creating atoms

- ``Atom``
- ``ComputedAtom``

### Reading and observing

- ``ReadableAtom``
- ``Subscription``

### Bridging to machines

- ``subscribeToAtom(_:map:)``
