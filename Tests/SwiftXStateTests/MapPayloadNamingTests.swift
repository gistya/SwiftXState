import Testing
@testable import SwiftXState

/// Multi-value payload events routed through the `Map` dot-syntax workaround recover their case NAME
/// (not the wildcard `*`) via the variadic `init(on: Map<(repeat each Payload), EventID>)` overload —
/// **provided the Map's tuple `In` is UNLABELED**, since a parameter pack only expands to an unlabeled
/// tuple (`(String, generation: Int?)` would fail to match and fall to the scalar `Payload: Blankable`
/// overload, which then reports "tuple cannot conform to Blankable").
@Suite("Map dot-syntax payload naming")
struct MapPayloadNamingTests {
    enum Ev: EventIdentifying {
        case launch
        case setVolume(Double)                                                // 1 value
        case audioFailed(String, generation: Int?)                            // 2 values
        case playbackPrepared(title: String?, generation: Int, started: Bool) // 3 values
        static var _blank: Ev { .launch }
    }
    enum S: String, StateIdentifying { case idle, busy; static var _blank: S { .idle } }

    struct M: StateMachine {
        typealias Context = Int
        typealias StateID = S
        typealias EventID = Ev
        var context: Int { 0 }
        var machine: some XStateMachine {
            State(.idle) {
                Transition(on: .setVolume, to: .busy)         // Map<Double>        → scalar Blankable
                Transition(on: .audioFailed, to: .busy)       // Map<(String,Int?)> → pack (2)
                Transition(on: .playbackPrepared, to: .busy)  // Map<(String?,Int,Bool)> → pack (3)
            }.initial()
            State(.busy) {}
        }
    }

    @Test func mapDotSyntaxRoutesMultiValueByName() throws {
        let json = try M().resolvedMachine(id: "m").definitionJSON()
        for name in ["setVolume", "audioFailed", "playbackPrepared"] {
            #expect(json.contains(name), "expected the graph/JSON to label the edge \(name), not *")
        }
        #expect(!json.contains("\"*\""))
    }

    @Test func multiValueMapEventRoutesToItsTransition() async {
        // The derived name keys the transition, so a real 2-value payload event reaches it.
        let m = createActor(M())
        await m.start()
        await m.send(.audioFailed("boom", generation: 1))
        #expect(await m.matches(.busy))
    }
}

// The dot-syntax `Map` workaround — UNLABELED tuple `In` so the variadic overload matches.
extension Map where In == Double, Out == MapPayloadNamingTests.Ev {
    static var setVolume: Self { .init(transform: Out.setVolume) }
}
extension Map where In == (String, Int?), Out == MapPayloadNamingTests.Ev {
    static var audioFailed: Self { .init(transform: Out.audioFailed) }
}
extension Map where In == (String?, Int, Bool), Out == MapPayloadNamingTests.Ev {
    static var playbackPrepared: Self { .init(transform: Out.playbackPrepared) }
}
