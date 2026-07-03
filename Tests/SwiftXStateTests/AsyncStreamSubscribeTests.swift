import Testing
@testable import SwiftXState

/// The additive `snapshots` AsyncStream API (sibling of the callback `subscribe`, same `notify`).
/// Determinism: awaiting the first (replayed) element synchronizes on continuation registration, so
/// subsequent sends are guaranteed to reach the continuation — no registration-hop race in the test.
@Suite("Additive AsyncStream snapshot subscription")
struct AsyncStreamSubscribeTests {
    enum S: String, StateIdentifying { case off, on; static var _blank: S { .off } }
    enum E: String, EventIdentifying { case toggle; static var _blank: E { .toggle } }
    struct Toggler: StateMachine {
        typealias Context = Int
        typealias StateID = S
        typealias EventID = E
        var context: Int { 0 }
        var machine: some XStateMachine {
            State(.off) { Transition(on: .toggle, to: .on) }.initial()
            State(.on) { Transition(on: .toggle, to: .off) }
        }
    }

    @Test func typedStreamReplaysCurrentThenUpdates() async {
        let m = createActor(Toggler())
        await m.start()
        var it = m.snapshots.makeAsyncIterator()

        let s0 = await it.next()            // replay: current value on subscribe
        #expect(s0?.0?.matches(.off) == true)

        await m.send(.toggle)
        let s1 = await it.next()
        #expect(s1?.0?.matches(.on) == true)

        await m.send(.toggle)
        let s2 = await it.next()
        #expect(s2?.0?.matches(.off) == true)
    }

    @Test func rawStreamIsMulticast() async {
        let m = createActor(Toggler())
        await m.start()
        let actor = m.actor

        var a = actor.snapshots(bufferingPolicy: .unbounded).makeAsyncIterator()
        var b = actor.snapshots(bufferingPolicy: .unbounded).makeAsyncIterator()
        _ = await a.next()                  // both register (replay off) before any send
        _ = await b.next()

        await m.send(.toggle)
        let av = await a.next()
        let bv = await b.next()
        #expect(av?.matches("on") == true)  // independent streams both see the same snapshot
        #expect(bv?.matches("on") == true)
    }

    @Test func streamFinishesOnStop() async {
        let m = createActor(Toggler())
        await m.start()
        let actor = m.actor
        var it = actor.snapshots(bufferingPolicy: .unbounded).makeAsyncIterator()
        _ = await it.next()                 // registered

        await actor.stop()
        var sawNil = false
        for _ in 0..<50 {                   // stop publishes a terminal snapshot, then finishes the stream
            if await it.next() == nil { sawNil = true; break }
        }
        #expect(sawNil)
    }

    struct Ctx: Sendable, Equatable { var count: Int }

    @Test func storeStreamReplaysUpdatesAndFinishes() async {
        let store = Store<Ctx, Event>(StoreConfig(
            context: Ctx(count: 0),
            on: ["inc": { @Sendable (ctx: inout Ctx, _: Event) in ctx.count += 1 }]
        ))
        var it = store.snapshots().makeAsyncIterator()

        let s0 = await it.next()            // replay count 0 (Store registers synchronously — no actor hop)
        #expect(s0?.context.count == 0)

        store.send(Event("inc"))
        let s1 = await it.next()
        #expect(s1?.context.count == 1)

        store.stop()
        var sawNil = false
        for _ in 0..<50 {
            if await it.next() == nil { sawNil = true; break }
        }
        #expect(sawNil)
    }
}
