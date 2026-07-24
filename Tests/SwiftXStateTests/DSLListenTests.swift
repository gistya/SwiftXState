import Testing
@testable import SwiftXState

/// `enq.listen` (XState v6): from inside a transition, subscribe to a **child** actor's emitted
/// events and relay a mapped event back into this machine. Torn down when the actor stops.
@Suite("Plan D — enq.listen (inter-actor)")
struct DSLListenTests {
    // Child: on PING, emit a "progress" event to its `on(_:)` listeners.
    enum WS: String, StateIdentifying { case idle; static var _blank: WS { .idle } }
    enum WE: String, EventIdentifying { case ping; static var _blank: WE { .ping } }
    struct Worker: StateMachine {
        typealias Context = Int; typealias StateID = WS; typealias EventID = WE
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.idle) {
                XTransition(on: .ping, to: .idle).action { _, enq in
                    enq.emit(EmittedEvent("progress"))
                    return 0
                }
            }.initial()
        }
    }

    // Parent: spawns the worker and listens to its "progress" emissions, relaying `.heard`.
    enum PS: String, StateIdentifying { case idle, listening, done; static var _blank: PS { .idle } }
    enum PE: String, EventIdentifying { case start, probe, heard; static var _blank: PE { .start } }
    struct Parent: StateMachine {
        typealias Context = Int; typealias StateID = PS; typealias EventID = PE
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.idle) {
                XTransition(on: .start, to: .listening).action { _, enq in
                    enq.spawn(Worker(), id: "worker", inspectable: false)   // register the child first…
                    enq.listen("worker", on: "progress") { _ in .heard }    // …then subscribe to it
                    return 0
                }
            }.initial()
            XState(.listening) {
                XTransition(on: .probe, to: .listening).action { _, enq in enq.sendTo("worker", WE.ping); return 0 }
                XTransition(on: .heard, to: .done)
            }
            XState(.done) {}
        }
    }

    @Test("a spawned child's emission relays back through enq.listen")
    func listensToChild() async {
        let actor = createActor(Parent().resolvedMachine())
        await actor.start(context: 0)
        await actor.send(PE.start.event)                     // spawn worker + register listen
        #expect(await actor.snapshot.value.matches("listening"))

        await actor.send(PE.probe.event)                     // worker gets PING → emits "progress" → relayed → .heard
        await actor.waitForSnapshot { $0.value.matches("done") }
        #expect(await actor.snapshot.value.matches("done"))
    }
}
