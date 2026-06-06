import Testing
@testable import SwiftXState

@Suite("History")
struct HistoryTests {
    func powerMachine(historyType: HistoryType?) -> StateMachine<EmptyContext> {
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
    func shallowHistory() {
        let actor = createActor(powerMachine(historyType: .shallow)).start()

        actor.send(Event("SWITCH"))
        actor.send(Event("POWER"))
        actor.send(Event("POWER"))

        #expect(actor.snapshot.value == .compound(["on": .atomic("second")]))
    }

    @Test("restores most recently visited state (default shallow)")
    func defaultShallowHistory() {
        let actor = createActor(powerMachine(historyType: nil)).start()

        actor.send(Event("SWITCH"))
        actor.send(Event("POWER"))
        actor.send(Event("POWER"))

        #expect(actor.snapshot.value == .compound(["on": .atomic("second")]))
    }

    @Test("falls back to initial state when no history (explicit shallow)")
    func shallowHistoryDefault() {
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

        let actor = createActor(machine).start()
        actor.send(Event("POWER"))

        #expect(actor.snapshot.value == .compound(["on": .atomic("first")]))
    }

    @Test("falls back to initial state when no history (default shallow)")
    func defaultShallowHistoryDefault() {
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

        let actor = createActor(machine).start()
        actor.send(Event("POWER"))

        #expect(actor.snapshot.value == .compound(["on": .atomic("first")]))
    }

    @Test("uses configured default target when history is machine initial state")
    func historyAsMachineInitial() {
        let machine = createMachine(MachineConfig(
            initial: "foo",
            context: EmptyContext(),
            states: [
                "foo": StateNodeConfig(type: .history, target: "bar"),
                "bar": StateNodeConfig(),
            ]
        ))

        let actor = createActor(machine).start()
        #expect(actor.snapshot.matches("bar"))
    }

    @Test("uses configured default target when history is region initial state")
    func historyAsRegionInitial() {
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

        let actor = createActor(machine).start()
        actor.send(Event("NEXT"))

        #expect(actor.snapshot.value == .compound(["bar": .atomic("qwe")]))
    }

    @Test("deep history restores nested leaf state")
    func deepHistory() {
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

        let actor = createActor(machine).start()
        actor.send(Event("GO"))
        actor.send(Event("LEAVE"))
        actor.send(Event("RETURN"))

        #expect(actor.snapshot.value == .compound([
            "parent": .compound(["child": .atomic("deep")]),
        ]))
    }
}