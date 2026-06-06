import Testing
@testable import SwiftXState

@Suite("Machine")
struct MachineTests {
    let pedestrianStates = StateNodeConfig<EmptyContext>(
        initial: "walk",
        states: [
            "walk": StateNodeConfig(on: ["PED_COUNTDOWN": .to("wait")]),
            "wait": StateNodeConfig(on: ["PED_COUNTDOWN": .to("stop")]),
            "stop": StateNodeConfig(),
        ]
    )

    var lightMachine: StateMachine<EmptyContext> {
        createMachine(MachineConfig(
            initial: "green",
            context: EmptyContext(),
            states: [
                "green": StateNodeConfig(on: [
                    "TIMER": .to("yellow"),
                    "POWER_OUTAGE": .to("red"),
                ]),
                "yellow": StateNodeConfig(on: [
                    "TIMER": .to("red"),
                    "POWER_OUTAGE": .to("red"),
                ]),
                "red": StateNodeConfig(
                    initial: "walk",
                    states: pedestrianStates.states,
                    on: ["TIMER": .to("green"), "POWER_OUTAGE": .to("red")]
                ),
            ]
        ))
    }

    @Test("registers machine states")
    func states() {
        let keys = Array(lightMachine.states.keys).sorted()
        #expect(keys == ["green", "red", "yellow"])
    }

    @Test("returns accepted events")
    func events() {
        #expect(lightMachine.events.contains("TIMER"))
        #expect(lightMachine.events.contains("POWER_OUTAGE"))
        #expect(lightMachine.events.contains("PED_COUNTDOWN"))
    }

    @Test("transitions through states")
    func transitions() {
        let actor = createActor(lightMachine).start()

        #expect(actor.snapshot.matches("green"))

        actor.send(Event("TIMER"))
        #expect(actor.snapshot.matches("yellow"))

        actor.send(Event("TIMER"))
        #expect(actor.snapshot.matches("red"))

        actor.send(Event("TIMER"))
        #expect(actor.snapshot.matches("green"))
    }

    @Test("nested states")
    func nestedStates() {
        let actor = createActor(lightMachine).start()

        actor.send(Event("TIMER"))
        actor.send(Event("TIMER"))
        #expect(actor.snapshot.matches("red"))

        actor.send(Event("PED_COUNTDOWN"))
        #expect(actor.snapshot.matches(StateValue.compound(["red": .atomic("wait")])))
    }
}