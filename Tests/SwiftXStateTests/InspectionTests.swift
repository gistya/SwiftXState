import Testing
@testable import SwiftXState

@Suite("Inspection / devtools MVP")
struct InspectionTests {
    @Test("emits actor, transition, snapshot, and action events on start")
    func startInspection() {
        let collector = InspectionCollector()

        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(entry: [.inline { _ in }]),
            ]
        ))

        let actor = createActor(
            machine,
            options: ActorOptions(inspect: collector.observe())
        ).start()

        let kinds = collector.recordedEvents().map(\.kind)
        #expect(kinds.contains(.actor))
        #expect(kinds.contains(.transition))
        #expect(kinds.contains(.snapshot))
        #expect(kinds.contains(.action))
        #expect(actor.actorSystem.rootSessionId == actor.id)
    }

    @Test("root actor registration carries the machine definition JSON")
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

        let actor = createActor(machine, options: ActorOptions(inspect: collector.observe())).start()

        let registration = collector.recordedEvents().first {
            $0.kind == .actor && $0.actor.sessionId == actor.id
        }
        #expect(registration != nil)
        // Inspectors graph type-erased actors from this; it must be present and parseable.
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

        let actor = createActor(
            machine,
            options: ActorOptions(inspect: collector.observe())
        ).start()
        collector.reset()

        actor.send(Event("GO"))

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

        let actor = createActor(
            machine,
            options: ActorOptions(inspect: collector.observe())
        ).start()
        collector.reset()

        actor.send(Event("GO"))

        let microsteps = collector.recordedEvents().filter { $0.kind == .microstep }
        #expect(!microsteps.isEmpty)
        #expect(microsteps.contains { $0.event?.type == "GO" })
        #expect(microsteps.contains { $0.transitions?.isEmpty == false })
    }

    @Test("emits actor event with machineId for invoked child machine")
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
                            src: .machine(MachineActorLogicBox(childMachine) { _ in EmptyContext() })
                        ),
                    ]
                ),
            ]
        ))

        _ = createActor(
            machine,
            options: ActorOptions(inspect: collector.observe())
        ).start()

        let actorEvents = collector.recordedEvents().filter { $0.kind == .actor }
        #expect(actorEvents.contains { $0.actor.sessionId == "pay" && $0.actor.machineId == "payment" })

        let paymentActor = actorEvents.first { $0.actor.sessionId == "pay" }
        #expect(paymentActor?.definitionJSON != nil)
        #expect(paymentActor?.definitionJSON?.contains("payment") == true)
    }

    @Test("emits actor event when spawning invoked child")
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

        _ = createActor(
            machine,
            options: ActorOptions(inspect: collector.observe())
        ).start()

        let actorEvents = collector.recordedEvents().filter { $0.kind == .actor }
        #expect(actorEvents.contains { $0.actor.sessionId == "worker" })
    }

    @Test("actor registration precedes inspectable spawn actions on start")
    func actorRegistrationBeforeSpawnActions() {
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

        let actor = createActor(
            parentMachine,
            options: ActorOptions(inspect: collector.observe())
        ).start()

        let events = collector.recordedEvents()
        let actorIndex = events.firstIndex { $0.kind == .actor && $0.actor.sessionId == actor.id }
        let spawnActionIndices = events.enumerated().compactMap { index, event in
            event.kind == .action && event.actionType == "xstate.spawnChild" ? index : nil
        }

        #expect(actorIndex != nil)
        #expect(spawnActionIndices.count == 1)
        #expect(actorIndex! < spawnActionIndices[0])
    }

    @Test("spawnChild with inspectable false does not register child actor")
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

        _ = createActor(
            parentMachine,
            options: ActorOptions(inspect: collector.observe())
        ).start()

        let hiddenEvents = collector.recordedEvents().filter { $0.actor.sessionId == "hidden" }
        #expect(hiddenEvents.isEmpty)

        let spawnActions = collector.recordedEvents().filter {
            $0.kind == .action && $0.actionType == "xstate.spawnChild"
        }
        #expect(spawnActions.isEmpty)
    }

    @Test("system.inspect receives events from existing actor")
    func systemInspect() {
        let collector = InspectionCollector()

        let machine = createMachine(MachineConfig(
            initial: "idle",
            context: EmptyContext(),
            states: [
                "idle": StateNodeConfig(on: ["PING": .single(TransitionConfig())]),
            ]
        ))

        let actor = createActor(machine).start()
        _ = actor.actorSystem.inspect(collector.observe())
        collector.reset()

        actor.send(Event("PING"))

        #expect(collector.recordedEvents().contains { $0.kind == .event && $0.event?.type == "PING" })
    }

    @Test("ConsoleInspector formats events")
    func consoleLine() {
        let event = InspectionEvent.transition(
            rootId: "root",
            actor: InspectionActorRef(sessionId: "root", machineId: "app"),
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