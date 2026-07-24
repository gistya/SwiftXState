import Testing
@testable import SwiftXState

/// `internalEvents` in the **typed** Plan-D DSL: declared with the machine's own `EventID` cases
/// (not raw strings) and lowered to their `name`s.
@Suite("Plan D — internal events (typed)")
struct DSLInternalEventsTests {
    enum S: String, StateIdentifying { case idle, waiting, caught; static var _blank: S { .idle } }
    enum E: String, EventIdentifying { case go, secret; static var _blank: E { .go } }

    struct M: StateMachine {
        typealias Context = Int
        typealias StateID = S
        typealias EventID = E
        var context: Int { 0 }
        var internalEvents: [E] { [.secret] }        // typed — no strings
        var machine: some XStateMachine {
            XState(.idle) {
                XTransition(on: .go, to: .waiting).action { args, enq in
                    enq.raise(.secret)               // internal raise — allowed
                    return args.context
                }
                XTransition(on: .secret, to: .caught) // reachable only if SECRET slips past the gate
            }.initial()
            XState(.waiting) { XTransition(on: .secret, to: .caught) }
            XState(.caught) {}
        }
    }

    @Test("typed internalEvents lower to their case names")
    func loweringToNames() {
        #expect(M().resolvedMachine().config.internalEvents == ["secret"])
    }

    @Test("external send of a typed internal event is rejected")
    func externalRejected() async {
        let actor = createActor(M().resolvedMachine())
        await actor.start(context: 0)
        await actor.send(E.secret.event)             // gated — SECRET is internal-only
        #expect(await actor.snapshot.value.matches("idle"))
    }

    @Test("internally raised typed internal event still routes")
    func internalRaiseWorks() async {
        let actor = createActor(M().resolvedMachine())
        await actor.start(context: 0)
        await actor.send(E.go.event)                 // go → waiting, raise .secret → caught
        #expect(await actor.snapshot.value.matches("caught"))
    }
}
