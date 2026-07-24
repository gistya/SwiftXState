import Testing
@testable import SwiftXState

@Suite("Plan D — enq effect channel (Phase 4)")
struct DSLEnqueueTests {
    enum S: String, StateIdentifying { case idle, working, done; static var _blank: S { .idle } }
    enum E: String, EventIdentifying { case start, auto; static var _blank: E { .start } }

    // idle --start--> working, whose action raises an internal `.auto` that chains working --> done,
    // all within one run-to-completion macrostep.
    struct Chain: StateMachine {
        typealias Context = Int
        typealias StateID = S
        typealias EventID = E
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.idle) {
                XTransition(on: .start, to: .working).action { args, enq in
                    enq.raise(.auto)        // queued — processed after this macrostep
                    return args.context + 1 // context patch
                }
            }.initial()
            XState(.working) {
                XTransition(on: .auto, to: .done)
            }
            XState(.done) {}
        }
    }

    @Test func raiseChainsTransitionWithinRTC() async {
        let actor = createActor(Chain().resolvedMachine())
        await actor.start(context: 0)
        #expect(await actor.snapshot.value.matches("idle"))

        await actor.send(E.start.event)
        let snap = await actor.snapshot
        #expect(snap.value.matches("done"))   // start → working, raised auto → done, in one send
        #expect(snap.context == 1)            // the start action's context patch applied
    }
}
