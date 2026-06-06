import Testing
@testable import SwiftXState

@Suite("State meta")
struct StateMetaTests {
    @Test("getMeta returns meta for the active atomic state")
    func activeStateMeta() {
        let machine = createMachine(MachineConfig(
            id: "traffic",
            initial: "green",
            context: EmptyContext(),
            states: [
                "green": StateNodeConfig(meta: ["color": SendableValue("green")]),
                "yellow": StateNodeConfig(meta: ["color": SendableValue("yellow")]),
                "red": StateNodeConfig(meta: ["color": SendableValue("red")]),
            ]
        ))

        let actor = createActor(machine).start()
        let meta = actor.snapshot.getMeta()

        #expect(meta.count == 1)
        #expect(meta["traffic.green"]?["color"]?.get(String.self) == "green")
    }

    @Test("getMeta updates after transition")
    func metaAfterTransition() {
        let machine = createMachine(MachineConfig(
            id: "traffic",
            initial: "green",
            context: EmptyContext(),
            states: [
                "green": StateNodeConfig(
                    on: ["NEXT": .single(TransitionConfig(target: "yellow"))],
                    meta: ["color": SendableValue("green")]
                ),
                "yellow": StateNodeConfig(meta: ["color": SendableValue("yellow")]),
            ]
        ))

        let actor = createActor(machine).start()
        actor.send(Event("NEXT"))

        let meta = actor.snapshot.getMeta()
        #expect(meta.count == 1)
        #expect(meta["traffic.yellow"]?["color"]?.get(String.self) == "yellow")
    }

    @Test("getMeta merges parallel region metas")
    func parallelRegionMeta() {
        let machine = createMachine(MachineConfig(
            id: "app",
            context: EmptyContext(),
            states: [
                "walk": StateNodeConfig(meta: ["signal": SendableValue("walk")]),
                "countdown": StateNodeConfig(meta: ["signal": SendableValue("countdown")]),
            ],
            type: .parallel
        ))

        let actor = createActor(machine).start()
        let meta = actor.snapshot.getMeta()

        #expect(meta.count == 2)
        #expect(meta["app.walk"]?["signal"]?.get(String.self) == "walk")
        #expect(meta["app.countdown"]?["signal"]?.get(String.self) == "countdown")
    }

    @Test("getMeta includes ancestor compound state meta")
    func nestedStateMeta() {
        let machine = createMachine(MachineConfig(
            id: "traffic",
            initial: "light",
            context: EmptyContext(),
            states: [
                "light": StateNodeConfig(
                    initial: "green",
                    states: [
                        "green": StateNodeConfig(meta: ["color": SendableValue("green")]),
                        "yellow": StateNodeConfig(meta: ["color": SendableValue("yellow")]),
                    ],
                    meta: ["scope": SendableValue("light")]
                ),
            ]
        ))

        let actor = createActor(machine).start()
        let meta = actor.snapshot.getMeta()

        #expect(meta.count == 2)
        #expect(meta["traffic.light"]?["scope"]?.get(String.self) == "light")
        #expect(meta["traffic.light.green"]?["color"]?.get(String.self) == "green")
    }

    @Test("definition JSON exports state meta")
    func metaDefinitionJSON() throws {
        let machine = createMachine(MachineConfig(
            id: "traffic",
            initial: "green",
            context: EmptyContext(),
            states: [
                "green": StateNodeConfig(meta: [
                    "color": SendableValue("green"),
                    "priority": SendableValue(1),
                ]),
            ]
        ))

        let json = try machine.definitionJSON()
        #expect(json.contains("\"meta\""))
        #expect(json.contains("\"color\":\"green\""))
        #expect(json.contains("\"priority\":1"))
    }
}