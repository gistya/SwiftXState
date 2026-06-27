import Testing
@testable import SwiftXState

@Suite("History")
struct HistoryTests {
    func powerMachine(historyType: HistoryType?) -> ResolvedMachine<EmptyContext> {
        createMachine(MachineConfig(
            initial: "on",
            context: EmptyContext(),
            states: [
                "on": StateNodeConfig(
                    initial: "first",
                    states: [
                        "first": StateNodeConfig(on: ["SWITCH": .to("second")]),
                        "second": StateNodeConfig(),
                        "hist": StateNodeConfig(
                            type: .history,
                            history: historyType
                        ),
                    ],
                    on: ["POWER": .to("off")]
                ),
                "off": StateNodeConfig(on: ["POWER": .to("on.hist")]),
            ]
        ))
    }

    @Test("restores most recently visited state (explicit shallow)")
    func shallowHistory() async {
        let actor = await createActor(powerMachine(historyType: .shallow)).start()

        await actor.send(Event("SWITCH"))
        await actor.send(Event("POWER"))
        await actor.send(Event("POWER"))

        #expect(await actor.snapshot.value == .compound(["on": .atomic("second")]))
    }

    @Test("restores most recently visited state (default shallow)")
    func defaultShallowHistory() async {
        let actor = await createActor(powerMachine(historyType: nil)).start()

        await actor.send(Event("SWITCH"))
        await actor.send(Event("POWER"))
        await actor.send(Event("POWER"))

        #expect(await actor.snapshot.value == .compound(["on": .atomic("second")]))
    }

    @Test("falls back to initial state when no history (explicit shallow)")
    func shallowHistoryDefault() async {
        let machine = createMachine(MachineConfig(
            initial: "off",
            context: EmptyContext(),
            states: [
                "off": StateNodeConfig(on: ["POWER": .to("on.hist")]),
                "on": StateNodeConfig(
                    initial: "first",
                    states: [
                        "first": StateNodeConfig(),
                        "second": StateNodeConfig(),
                        "hist": StateNodeConfig(type: .history, history: .shallow),
                    ]
                ),
            ]
        ))

        let actor = await createActor(machine).start()
        await actor.send(Event("POWER"))

        #expect(await actor.snapshot.value == .compound(["on": .atomic("first")]))
    }

    @Test("falls back to initial state when no history (default shallow)")
    func defaultShallowHistoryDefault() async {
        let machine = createMachine(MachineConfig(
            initial: "off",
            context: EmptyContext(),
            states: [
                "off": StateNodeConfig(on: ["POWER": .to("on.hist")]),
                "on": StateNodeConfig(
                    initial: "first",
                    states: [
                        "first": StateNodeConfig(),
                        "second": StateNodeConfig(),
                        "hist": StateNodeConfig(type: .history),
                    ]
                ),
            ]
        ))

        let actor = await createActor(machine).start()
        await actor.send(Event("POWER"))
        #expect(await actor.snapshot.value == .compound(["on": .atomic("first")]))
    }

    @Test("uses configured default target when history is machine initial state")
    func historyAsMachineInitial() async {
        let machine = createMachine(MachineConfig(
            initial: "foo",
            context: EmptyContext(),
            states: [
                "foo": StateNodeConfig(type: .history, target: "bar"),
                "bar": StateNodeConfig(),
            ]
        ))

        let actor = await createActor(machine).start()
        #expect(await actor.snapshot.matches("bar"))
    }

    @Test("uses configured default target when history is region initial state")
    func historyAsRegionInitial() async {
        let machine = createMachine(MachineConfig(
            initial: "foo",
            context: EmptyContext(),
            states: [
                "foo": StateNodeConfig(on: ["NEXT": .to("bar")]),
                "bar": StateNodeConfig(
                    initial: "baz",
                    states: [
                        "baz": StateNodeConfig(type: .history, target: "qwe"),
                        "qwe": StateNodeConfig(),
                    ]
                ),
            ]
        ))

        let actor = await createActor(machine).start()
        await actor.send(Event("NEXT"))

        #expect(await actor.snapshot.value == .compound(["bar": .atomic("qwe")]))
    }

    @Test("deep history restores nested leaf state")
    func deepHistory() async {
        let machine = createMachine(MachineConfig(
            initial: "parent",
            context: EmptyContext(),
            states: [
                "parent": StateNodeConfig(
                    initial: "child",
                    states: [
                        "child": StateNodeConfig(
                            initial: "leaf",
                            states: [
                                "leaf": StateNodeConfig(on: ["GO": .to("deep")]),
                                "deep": StateNodeConfig(),
                                "hist": StateNodeConfig(type: .history, history: .deep),
                            ]
                        ),
                        "hist": StateNodeConfig(type: .history, history: .deep),
                    ],
                    on: ["LEAVE": .to("other")]
                ),
                "other": StateNodeConfig(on: ["RETURN": .to("parent.hist")]),
            ]
        ))

        let actor = await createActor(machine).start()
        await actor.send(Event("GO"))
        await actor.send(Event("LEAVE"))
        await actor.send(Event("RETURN"))

        #expect(await actor.snapshot.value == .compound([
            "parent": .compound(["child": .atomic("deep")]),
        ]))
    }
}
