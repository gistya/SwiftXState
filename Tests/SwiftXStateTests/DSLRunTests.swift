import Testing
@testable import SwiftXState

@Suite("Plan D — typed machine runs on the engine (Phase 3b)")
struct DSLRunTests {
    struct TrafficContext: Sendable, Equatable {
        var cycles: Int = 0
        func incrementingCycles() -> Self { .init(cycles: cycles + 1) }
    }
    enum LightState: String, StateIdentifying { case red, green, yellow; static var _blank: LightState { .red } }
    enum LightEvent: String, EventIdentifying { case go, caution, stop; static var _blank: LightEvent { .stop } }

    struct TrafficLight: StateMachine {
        typealias Context = TrafficContext
        typealias StateID = LightState
        typealias EventID = LightEvent
        var machine: some XStateMachine {
            XState(.red)    { XTransition(on: .go,      to: .green)  }.initial()
            XState(.green)  { XTransition(on: .caution, to: .yellow) }
            XState(.yellow) { XTransition(on: .stop, to: .red).action { $0.incrementingCycles() } }
        }
    }

    @Test func runsEndToEnd() async {
        let light = TrafficLight()
        let schema = light.buildSchema()
        let actor = createActor(light.resolvedMachine())
        await actor.start(context: TrafficContext())

        #expect(schema.configuration(from: await actor.snapshot.value) == .atomic(.red))

        await actor.send(LightEvent.go.event)
        #expect(schema.configuration(from: await actor.snapshot.value) == .atomic(.green))

        await actor.send(LightEvent.caution.event)
        #expect(schema.configuration(from: await actor.snapshot.value) == .atomic(.yellow))

        await actor.send(LightEvent.stop.event)
        let final = await actor.snapshot
        #expect(schema.configuration(from: final.value) == .atomic(.red))
        #expect(final.context.cycles == 1)   // the yellow→red `.action` ran
    }

    @Test func guardBlocksTransition() async {
        struct Gate: StateMachine {
            typealias Context = Int
            typealias StateID = LightState
            typealias EventID = LightEvent
            var machine: some XStateMachine {
                XState(.red) { XTransition(on: .go, to: .green).when { $0 > 0 } }.initial()
                XState(.green) {}
            }
        }
        let blocked = createActor(Gate().resolvedMachine())
        await blocked.start(context: 0)
        await blocked.send(LightEvent.go.event)
        #expect(await blocked.snapshot.value.matches("red"))   // guard failed

        let open = createActor(Gate().resolvedMachine())
        await open.start(context: 1)
        await open.send(LightEvent.go.event)
        #expect(await open.snapshot.value.matches("green"))    // guard passed
    }

    @Test func stringMachineRuns() async {
        struct Toggle: StateMachine {
            typealias Context = Int
            typealias StateID = String
            typealias EventID = String
            var machine: some XStateMachine {
                XState("off") { XTransition(on: "FLIP", to: "on") }.initial()
                XState("on")  { XTransition(on: "FLIP", to: "off") }
            }
        }
        let actor = createActor(Toggle().resolvedMachine())
        await actor.start(context: 0)
        #expect(await actor.snapshot.value.matches("off"))
        await actor.send(Event("FLIP"))
        #expect(await actor.snapshot.value.matches("on"))
    }
}
