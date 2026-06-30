import Testing
@testable import SwiftXState

@Suite("Plan D — typed cross-actor sendTo (payload survives)")
struct DSLCrossActorTests {
    actor Recorder {
        private(set) var received: [Bool] = []
        func add(_ value: Bool) { received.append(value) }
        var count: Int { received.count }
    }

    // A child machine whose action reads the Bool payload of an event sent by its parent.
    enum LightState: String, StateIdentifying { case active; static var _blank: LightState { .active } }
    enum LightEvent: EventIdentifying { case set(on: Bool); static var _blank: LightEvent { .set(on: false) } }
    struct Light: StateMachine {
        typealias Context = Int
        typealias StateID = LightState
        typealias EventID = LightEvent
        let recorder: Recorder
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.active) {
                XTransition(on: LightEvent.set, to: .active).action { args, _ in
                    if case let .set(on)? = args.event {
                        let recorder = recorder
                        Task { await recorder.add(on) }
                    }
                    return args.context
                }
            }.initial()
        }
    }

    enum HubState: String, StateIdentifying { case running; static var _blank: HubState { .running } }
    enum HubEvent: String, EventIdentifying { case spawnBulb, turnOn, turnOff; static var _blank: HubEvent { .spawnBulb } }
    struct Hub: StateMachine {
        typealias Context = Int
        typealias StateID = HubState
        typealias EventID = HubEvent
        let recorder: Recorder
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.running) {
                XTransition(on: .spawnBulb, to: .running).action { _, enq in
                    enq.spawn(Light(recorder: recorder), id: "bulb", inspectable: false); return 0
                }
                // Send the CHILD's typed event (different machine) with a payload — the cross-actor channel.
                XTransition(on: .turnOn, to: .running).action { _, enq in
                    enq.sendTo("bulb", LightEvent.set(on: true)); return 0
                }
                XTransition(on: .turnOff, to: .running).action { _, enq in
                    enq.sendTo("bulb", LightEvent.set(on: false)); return 0
                }
            }.initial()
        }
    }

    @Test func childReadsPayloadDeliveredFromParent() async {
        let recorder = Recorder()
        let hub = createActor(Hub(recorder: recorder))
        await hub.start()
        await hub.send(.spawnBulb)
        await hub.actor.waitForSnapshot { $0.children["bulb"] != nil }

        await hub.send(.turnOn)    // → enq.sendTo("bulb", .set(on: true))
        await hub.send(.turnOff)   // → enq.sendTo("bulb", .set(on: false))

        var spins = 0
        while await recorder.count < 2, spins < 10_000 { await Task.yield(); spins += 1 }
        // Both distinct payloads crossed the actor boundary (proves it's not just the discriminant).
        #expect(Set(await recorder.received) == [true, false])
    }
}
