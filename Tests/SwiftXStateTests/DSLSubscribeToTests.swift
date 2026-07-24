import Testing
@testable import SwiftXState

/// `enq.subscribeTo` (XState v6): from inside a transition, subscribe to a **child** actor's snapshot
/// changes (status / value) and relay a mapped event back into this machine. Torn down on stop.
@Suite("Plan D — enq.subscribeTo (inter-actor)")
struct DSLSubscribeToTests {
    enum WS: String, StateIdentifying { case idle, finished; static var _blank: WS { .idle } }
    enum WE: String, EventIdentifying { case advance; static var _blank: WE { .advance } }
    struct Worker: StateMachine {
        typealias Context = Int; typealias StateID = WS; typealias EventID = WE
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.idle) { XTransition(on: .advance, to: .finished) }.initial()
            XState(.finished) {}
        }
    }

    enum PS: String, StateIdentifying { case idle, watching, done; static var _blank: PS { .idle } }
    enum PE: String, EventIdentifying { case start, probe, heard; static var _blank: PE { .start } }
    struct Parent: StateMachine {
        typealias Context = Int; typealias StateID = PS; typealias EventID = PE
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.idle) {
                XTransition(on: .start, to: .watching).action { _, enq in
                    enq.spawn(Worker(), id: "worker", inspectable: false)
                    enq.subscribeTo("worker") { snap in
                        (snap.value ?? "").hasSuffix("finished") ? .heard : nil
                    }
                    return 0
                }
            }.initial()
            XState(.watching) {
                XTransition(on: .probe, to: .watching).action { _, enq in enq.sendTo("worker", WE.advance); return 0 }
                XTransition(on: .heard, to: .done)
            }
            XState(.done) {}
        }
    }

    @Test("a child's snapshot change relays back through enq.subscribeTo")
    func subscribesToChildSnapshot() async {
        let actor = createActor(Parent().resolvedMachine())
        await actor.start(context: 0)
        await actor.send(PE.start.event)                     // spawn worker + subscribe to its snapshots
        #expect(await actor.snapshot.value.matches("watching"))

        await actor.send(PE.probe.event)                     // worker → finished → snapshot relayed → .heard
        await actor.waitForSnapshot { $0.value.matches("done") }
        #expect(await actor.snapshot.value.matches("done"))
    }
}
