import Testing
@testable import SwiftXState

/// Payload-carrying event transitions derive their case NAME (via a Blankable sample + Mirror), so they
/// route under `"setVolume"` instead of the wildcard `*` — visible in the definition JSON and the graph.
/// Mirrors the shape of a real SoundtrackEvent (no payload / single / labeled / multi-value / optional).
@Suite("Payload event case-name derivation (Blankable)")
struct BlankableCaseNameTests {
    enum SoundEvent: EventIdentifying {
        case launch
        case setVolume(Double)
        case setInsertSlot(index: Int, component: String?)                          // 2 values, one optional
        case toggleInsertBypass(index: Int)                                         // 1 value (shares Int)
        case playbackPrepared(moduleTitle: String?, generation: Int, started: Bool) // 3 values
        case playbackPaused(generation: Int)                                        // 1 value (shares Int)
        case audioRequestHandled(Int)                                               // 1 value (shares Int)
        static var _blank: SoundEvent { .launch }
    }
    enum S: String, StateIdentifying { case idle, busy; static var _blank: S { .idle } }

    struct M: StateMachine {
        typealias Context = Int
        typealias StateID = S
        typealias EventID = SoundEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            State(.idle) {
                Transition(on: .launch, to: .busy)                          // no payload (value form)
                Transition(on: SoundEvent.setVolume, to: .busy)             // 1
                Transition(on: SoundEvent.setInsertSlot, to: .busy)         // 2 (Int + Optional)
                Transition(on: SoundEvent.playbackPrepared, to: .busy)      // 3
                Transition(on: SoundEvent.playbackPaused, to: .busy)        // 1 (Int)
            }.initial()
            State(.busy) {}
        }
    }

    @Test func definitionJSONKeysUnderDerivedNames() throws {
        let json = try M().resolvedMachine(id: "snd").definitionJSON()
        for name in ["launch", "setVolume", "setInsertSlot", "playbackPrepared", "playbackPaused"] {
            #expect(json.contains(name))                     // the graph reads these as edge labels
        }
    }

    @Test func payloadEventRoutesByName() async {
        // Routing proof: the derived name keys the transition, so a real payload event reaches it.
        let m = createActor(M())
        await m.start()
        await m.send(.setInsertSlot(index: 2, component: nil))   // 2-value payload event
        #expect(await m.matches(.busy))
    }

    @Test func sharedPayloadTypeCasesGetDistinctNames() {
        // The three Int-payload cases must resolve to their OWN names (this is what defeated the
        // metadata / payload-type-switch approaches — same payload type, different case).
        #expect(SoundEvent.toggleInsertBypass(index: 0).name == "toggleInsertBypass")
        #expect(SoundEvent.playbackPaused(generation: 0).name == "playbackPaused")
        #expect(SoundEvent.audioRequestHandled(0).name == "audioRequestHandled")
    }
}
