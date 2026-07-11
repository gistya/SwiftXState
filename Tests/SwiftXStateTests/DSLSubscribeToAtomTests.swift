import Testing
@testable import SwiftXState

/// `enq.subscribeTo(atom)` (XState v6): from inside a transition, subscribe to a reactive ``Atom`` and
/// relay a mapped event back into this machine when it changes. Torn down on stop.
@Suite("Plan D — enq.subscribeTo(atom)")
struct DSLSubscribeToAtomTests {
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
                    enq.subscribeTo(threshold) { value in value > 10 ? .over : nil }
                    return 0
                }
            }.initial()
            XState(.watching) {
                XTransition(on: .over, to: .exceeded)
            }
            XState(.exceeded) {}
        }
    }

    @Test("a machine reacts to an atom crossing a threshold")
    func reactsToAtom() async {
        let threshold = Atom(0)
        let actor = createActor(Watcher(threshold: threshold).resolvedMachine())
        await actor.start(context: 0)
        await actor.send(PE.start.event)                     // subscribes; current value 0 → no event
        #expect(await actor.snapshot.value.matches("watching"))

        threshold.value = 20                                  // > 10 → relayed → .over → exceeded
        await actor.waitForSnapshot { $0.value.matches("exceeded") }
        #expect(await actor.snapshot.value.matches("exceeded"))
    }

    @Test("the atom subscription is torn down when the actor stops")
    func teardownOnStop() async {
        let threshold = Atom(0)
        let actor = createActor(Watcher(threshold: threshold).resolvedMachine())
        await actor.start(context: 0)
        await actor.send(PE.start.event)
        await actor.stop()                                    // cancels the atom subscription
        threshold.value = 99                                  // no live relay; must not crash or transition
        #expect(await actor.snapshot.status == .stopped)
    }
}
