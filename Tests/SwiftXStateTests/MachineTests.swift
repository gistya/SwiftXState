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
    func transitions() async {
        let actor = await createActor(lightMachine).start()

        #expect(await actor.snapshot.matches("green"))

        await actor.send(Event("TIMER"))
        #expect(await actor.snapshot.matches("yellow"))

        await actor.send(Event("TIMER"))
        #expect(await actor.snapshot.matches("red"))

        await actor.send(Event("TIMER"))
        #expect(await actor.snapshot.matches("green"))
    }

    @Test("nested states")
    func nestedStates() async {
        let actor = await createActor(lightMachine).start()

        await actor.send(Event("TIMER"))
        await actor.send(Event("TIMER"))
        #expect(await actor.snapshot.matches("red"))

        await actor.send(Event("PED_COUNTDOWN"))
        #expect(await actor.snapshot.matches(StateValue.compound(["red": .atomic("wait")])))
    }
}
