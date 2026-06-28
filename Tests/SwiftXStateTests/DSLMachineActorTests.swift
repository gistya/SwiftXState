import Testing
@testable import SwiftXState

@Suite("Plan D — typed actor facade (Phase 5)")
struct DSLMachineActorTests {
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
        var context: TrafficContext { .init() }
        var machine: some XStateMachine {
            XState(.red)    { XTransition(on: .go,      to: .green)  }.initial()
            XState(.green)  { XTransition(on: .caution, to: .yellow) }
            XState(.yellow) { XTransition(on: .stop, to: .red).action { $0.incrementingCycles() } }
        }
    }

    @Test func typedSendAndMatch() async {
        // No `.event`, no `schema.configuration(from:)` anywhere below — the whole surface is typed.
        let light = createActor(TrafficLight())
        let initial = await light.start()

        #expect(initial == .atomic(.red))
        #expect(await light.matches(.red))

        let afterGo = await light.send(.go)
        #expect(afterGo == .atomic(.green))
        #expect(await light.matches(.green))

        await light.send(.caution)
        #expect(await light.matches(.yellow))

        let afterStop = await light.send(.stop)
        #expect(afterStop == .atomic(.red))
        #expect(await light.context.cycles == 1)   // the yellow→red `.action` ran
    }

    @Test func machineDotActorConvenience() async {
        let light = TrafficLight().actor()
        await light.start()
        await light.send(.go)
        #expect(await light.matches(.green))
    }

    @Test func typedSubscribeProjectsConfiguration() async {
        let light = createActor(TrafficLight())

        actor Recorder { var configs: [Configuration<LightState>] = []; func add(_ c: Configuration<LightState>) { configs.append(c) } }
        let recorder = Recorder()
        let sub = await light.subscribe { config, _ in
            if let config { Task { await recorder.add(config) } }
        }

        await light.start()
        await light.send(.go)
        await light.send(.caution)
        sub.cancel()

        // The subscription saw typed configurations (ordering/coalescing aside, green & yellow appeared).
        // Give the detached recorder tasks a chance to drain.
        while await recorder.configs.count < 2 { await Task.yield() }
        let seen = Set(await recorder.configs.flatMap { $0.activeLeaves })
        #expect(seen.contains(.green))
        #expect(seen.contains(.yellow))
    }

    @Test func declaredContextSeedsStart() async {
        // `start()` takes no context — TrafficLight.context (XState v6 `createMachine({ context })`)
        // is baked into the engine config and seeds the initial context.
        struct Counting: StateMachine {
            typealias Context = TrafficContext
            typealias StateID = LightState
            typealias EventID = LightEvent
            var context: TrafficContext { .init(cycles: 7) }
            var machine: some XStateMachine {
                XState(.red) { XTransition(on: .go, to: .green) }.initial()
                XState(.green) {}
            }
        }
        let m = createActor(Counting())
        await m.start()
        #expect(await m.context.cycles == 7)            // declared context seeded the actor
    }

    @Test func startContextOverrideWins() async {
        struct Counting: StateMachine {
            typealias Context = TrafficContext
            typealias StateID = LightState
            typealias EventID = LightEvent
            var context: TrafficContext { .init(cycles: 7) }
            var machine: some XStateMachine {
                XState(.red) {}.initial()
            }
        }
        let m = createActor(Counting())
        await m.start(context: TrafficContext(cycles: 99))
        #expect(await m.context.cycles == 99)           // explicit start(context:) beats the declared one
    }

    @Test func untypedEscapeHatchStillReachable() async {
        // `actor` exposes the raw engine actor for untyped sends / inspection.
        let light = createActor(TrafficLight())
        await light.start()
        await light.actor.send(LightEvent.go.event)
        #expect(await light.matches(.green))
    }
}
