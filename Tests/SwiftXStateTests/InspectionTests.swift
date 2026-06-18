import Testing
@testable import SwiftXState

@Suite("Inspection / devtools MVP")
struct InspectionTests {
    @Test("emits reactor, transition, snapshot, and action events on start")
    func startInspection() {
        let collector = InspectionCollector()

        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(entry: [.inline { _ in }]),
            ]
        ))

        let reactor = createReactor(
            machine,
            options: ReactorOptions(inspect: collector.observe())
        ).start()

        let kinds = collector.recordedEvents().map(\.kind)
        #expect(kinds.contains(.reactor))
        #expect(kinds.contains(.transition))
        #expect(kinds.contains(.snapshot))
        #expect(kinds.contains(.action))
        #expect(reactor.reactorSystem.rootSessionId == reactor.id)
    }

    @Test("root reactor registration carries the machine definition JSON")
    func rootRegistrationDefinition() {
        let collector = InspectionCollector()

        let machine = createMachine(MachineConfig(
            id: "lights",
            initial: "green",
            context: EmptyContext(),
            states: [
                "green": StateNodeConfig(on: ["NEXT": .to("yellow")]),
                "yellow": StateNodeConfig(on: ["NEXT": .to("red")]),
                "red": StateNodeConfig(on: ["NEXT": .to("green")]),
            ]
        ))

        let reactor = createReactor(machine, options: ReactorOptions(inspect: collector.observe())).start()

        let registration = collector.recordedEvents().first {
            $0.kind == .reactor && $0.reactor.sessionId == reactor.id
        }
        #expect(registration != nil)
        // Inspectors graph type-erased reactors from this; it must be present and parseable.
        #expect(registration?.definitionJSON != nil)
        #expect(registration?.definitionJSON?.contains("green") == true)
        #expect(registration?.definitionJSON?.contains("\"NEXT\"") == true)
    }

    @Test("emits event and transition when sending")
    func sendInspection() {
        let collector = InspectionCollector()

        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(on: ["GO": .to("done")]),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let reactor = createReactor(
            machine,
            options: ReactorOptions(inspect: collector.observe())
        ).start()
        collector.reset()

        reactor.send(Event("GO"))

        let events = collector.recordedEvents()
        #expect(events.contains { $0.kind == .event && $0.event?.type == "GO" })
        #expect(events.contains { $0.kind == .transition && $0.event?.type == "GO" })
        #expect(events.contains { $0.kind == .snapshot && $0.snapshot?.value == "done" })
    }

    @Test("emits microstep events when sending")
    func microstepInspection() {
        let collector = InspectionCollector()

        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(on: ["GO": .to("done")]),
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let reactor = createReactor(
            machine,
            options: ReactorOptions(inspect: collector.observe())
        ).start()
        collector.reset()

        reactor.send(Event("GO"))

        let microsteps = collector.recordedEvents().filter { $0.kind == .microstep }
        #expect(!microsteps.isEmpty)
        #expect(microsteps.contains { $0.event?.type == "GO" })
        #expect(microsteps.contains { $0.transitions?.isEmpty == false })
    }

    @Test("emits reactor event with machineId for invoked child machine")
    func spawnedMachineInspection() async {
        let collector = InspectionCollector()

        let childMachine = createMachine(MachineConfig(
            id: "payment",
            initial: "done",
            context: EmptyContext(),
            states: [
                "done": StateNodeConfig(type: .final),
            ]
        ))

        let machine = createMachine(MachineConfig(
            initial: "running",
            context: EmptyContext(),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "pay",
                            src: .machine(MachineReactorLogicBox(childMachine) { _ in EmptyContext() })
                        ),
                    ]
                ),
            ]
        ))

        _ = createReactor(
            machine,
            options: ReactorOptions(inspect: collector.observe())
        ).start()

        let reactorEvents = collector.recordedEvents().filter { $0.kind == .reactor }
        #expect(reactorEvents.contains { $0.reactor.sessionId == "pay" && $0.reactor.machineId == "payment" })

        let paymentReactor = reactorEvents.first { $0.reactor.sessionId == "pay" }
        #expect(paymentReactor?.definitionJSON != nil)
        #expect(paymentReactor?.definitionJSON?.contains("payment") == true)
    }

    @Test("emits reactor event when spawning invoked child")
    func spawnInspection() async {
        let collector = InspectionCollector()

        let machine = createMachine(MachineConfig(
            initial: "running",
            context: EmptyContext(),
            states: [
                "running": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "worker",
                            src: fromTask { _ in
                                try await Task.sleep(for: .milliseconds(5))
                                return true
                            }
                        ),
                    ]
                ),
            ]
        ))

        _ = createReactor(
            machine,
            options: ReactorOptions(inspect: collector.observe())
        ).start()

        let reactorEvents = collector.recordedEvents().filter { $0.kind == .reactor }
        #expect(reactorEvents.contains { $0.reactor.sessionId == "worker" })
    }

    @Test("reactor registration precedes inspectable spawn actions on start")
    func reactorRegistrationBeforeSpawnActions() {
        let collector = InspectionCollector()

        let childMachine = createMachine(MachineConfig(
            id: "visible-child",
            initial: "idle",
            context: EmptyContext(),
            states: ["idle": StateNodeConfig()]
        ))

        let parentMachine = createMachine(MachineConfig(
            id: "parent",
            initial: "boot",
            context: EmptyContext(),
            states: [
                "boot": StateNodeConfig(
                    always: [TransitionConfig(target: "ready")],
                    entry: [
                        spawnChild(
                            fromMachine(childMachine),
                            id: "hidden",
                            inspectable: false
                        ),
                        spawnChild(
                            fromMachine(childMachine),
                            id: "visible",
                            inspectable: true
                        ),
                    ]
                ),
                "ready": StateNodeConfig(),
            ]
        ))

        let reactor = createReactor(
            parentMachine,
            options: ReactorOptions(inspect: collector.observe())
        ).start()

        let events = collector.recordedEvents()
        let reactorIndex = events.firstIndex { $0.kind == .reactor && $0.reactor.sessionId == reactor.id }
        let spawnActionIndices = events.enumerated().compactMap { index, event in
            event.kind == .action && event.actionType == "xstate.spawnChild" ? index : nil
        }

        #expect(reactorIndex != nil)
        #expect(spawnActionIndices.count == 1)
        #expect(reactorIndex! < spawnActionIndices[0])
    }

    @Test("spawnChild with inspectable false does not register child reactor")
    func hiddenSpawnInspection() async {
        let collector = InspectionCollector()

        let childMachine = createMachine(MachineConfig(
            id: "hidden-child",
            initial: "idle",
            context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(),
            ]
        ))

        let parentMachine = createMachine(MachineConfig(
            initial: "boot",
            context: EmptyContext(),
            states: [
                "boot": StateNodeConfig(
                    always: [TransitionConfig(target: "ready")],
                    entry: [
                        spawnChild(
                            fromMachine(childMachine),
                            id: "hidden",
                            inspectable: false
                        ),
                    ]
                ),
                "ready": StateNodeConfig(),
            ]
        ))

        _ = createReactor(
            parentMachine,
            options: ReactorOptions(inspect: collector.observe())
        ).start()

        let hiddenEvents = collector.recordedEvents().filter { $0.reactor.sessionId == "hidden" }
        #expect(hiddenEvents.isEmpty)

        let spawnActions = collector.recordedEvents().filter {
            $0.kind == .action && $0.actionType == "xstate.spawnChild"
        }
        #expect(spawnActions.isEmpty)
    }

    @Test("system.inspect receives events from existing reactor")
    func systemInspect() {
        let collector = InspectionCollector()

        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(on: ["PING": .single(TransitionConfig())]),
            ]
        ))

        let reactor = createReactor(machine).start()
        _ = reactor.reactorSystem.inspect(collector.observe())
        collector.reset()

        reactor.send(Event("PING"))

        #expect(collector.recordedEvents().contains { $0.kind == .event && $0.event?.type == "PING" })
    }

    @Test("ConsoleInspector formats events")
    func consoleLine() {
        let event = InspectionEvent.transition(
            rootId: "root",
            reactor: InspectionReactorRef(sessionId: "root", machineId: "app"),
            triggeringEvent: Event("GO"),
            machineSnapshot: MachineSnapshot(
                machine: createMachine(MachineConfig(initial: "done", context: EmptyContext(), states: ["done": StateNodeConfig()])),
                value: .atomic("done"),
                context: EmptyContext(),
                nodes: [],
                tags: [],
                status: .active
            )
        )

        #expect(event.consoleLine.contains("@xstate.transition"))
        #expect(event.consoleLine.contains("event=GO"))
        #expect(event.consoleLine.contains("state=done"))
    }
}
