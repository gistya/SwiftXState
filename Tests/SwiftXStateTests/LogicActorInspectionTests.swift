import Testing
import Foundation
@testable import SwiftXState

/// Proves the inspection stream ported onto `LogicActor` matches `Actor`'s for the core lifecycle
/// event kinds (`@xstate.actor` / `.event` / `.transition` / `.snapshot`). `.microstep` and
/// `.action` inspection are not yet ported, so they're filtered out of the comparison.
@Suite("LogicActor inspection parity")
struct LogicActorInspectionTests {

    private let coreKinds: Set<InspectionEventKind> = [.actor, .event, .transition, .snapshot]

    private func core(_ events: [InspectionEvent]) -> [(InspectionEventKind, String?)] {
        events.filter { coreKinds.contains($0.kind) }.map { ($0.kind, $0.snapshot?.value) }
    }

    @Test("core event stream matches Actor for start + a transition")
    func coreStreamParity() async {
        let machine = createMachine(MachineConfig(
            id: "toggle", initial: "off", context: EmptyContext(),
            states: [
                "off": StateNodeConfig(on: ["TOGGLE": .to("on")]),
                "on": StateNodeConfig(on: ["TOGGLE": .to("off")]),
            ]
        ))

        let oldCollector = InspectionCollector()
        let newCollector = InspectionCollector()

        let old = await createActor(machine, id: "p", options: ActorOptions(inspect: oldCollector.observe(), inspectable: true)).start()
        let new = await LogicActor(MachineLogic(machine: machine), id: "p", options: ActorOptions(inspect: newCollector.observe(), inspectable: true)).start()
        await old.send(Event("TOGGLE"))
        await new.send(Event("TOGGLE"))

        let oldCore = core(oldCollector.recordedEvents())
        let newCore = core(newCollector.recordedEvents())

        #expect(oldCore.map(\.0) == newCore.map(\.0))           // same kind sequence
        #expect(oldCore.map(\.1) == newCore.map(\.1))           // same snapshot values
        // Sanity: the lifecycle we expect — registration, init transition/event/snapshot, then the
        // TOGGLE event/transition/snapshot.
        #expect(newCore.map(\.0) == [.actor, .transition, .event, .snapshot, .event, .transition, .snapshot])
    }

    @Test("registration carries definitionJSON, like Actor")
    func registrationDefinition() async {
        let machine = createMachine(MachineConfig(
            id: "m", initial: "a", context: EmptyContext(),
            states: ["a": StateNodeConfig()]
        ))
        let oldCollector = InspectionCollector()
        let newCollector = InspectionCollector()
        _ = await createActor(machine, id: "p", options: ActorOptions(inspect: oldCollector.observe(), inspectable: true)).start()
        _ = await LogicActor(MachineLogic(machine: machine), id: "p", options: ActorOptions(inspect: newCollector.observe(), inspectable: true)).start()

        let oldActor = oldCollector.recordedEvents().first { $0.kind == .actor }
        let newActor = newCollector.recordedEvents().first { $0.kind == .actor }
        #expect(oldActor?.definitionJSON != nil)
        #expect(newActor?.definitionJSON != nil)
        #expect(oldActor?.definitionJSON == newActor?.definitionJSON)
    }

    @Test("inspectable: false (or no inspector) emits nothing")
    func noInspection() async {
        let machine = createMachine(MachineConfig(
            id: "m", initial: "a", context: EmptyContext(),
            states: ["a": StateNodeConfig(on: ["GO": .to("a")])]
        ))
        let collector = InspectionCollector()
        let actor = await LogicActor(MachineLogic(machine: machine), options: ActorOptions(inspect: collector.observe(), inspectable: false)).start()
        await actor.send(Event("GO"))
        #expect(collector.recordedEvents().isEmpty)
    }

    @Test("invoked child registers an @xstate.actor event, like Actor")
    func childRegistration() async {
        let child = createMachine(MachineConfig(initial: "run", context: EmptyContext(),
            states: ["run": StateNodeConfig()]))
        let parent = createMachine(MachineConfig(
            id: "parent", initial: "active", context: EmptyContext(),
            states: [
                "active": StateNodeConfig(invoke: [
                    InvokeConfig(id: "kid", src: .machine(MachineActorLogicBox(child) { _ in EmptyContext() })),
                ]),
            ]
        ))
        let oldCollector = InspectionCollector()
        let newCollector = InspectionCollector()
        _ = await createActor(parent, id: "p", options: ActorOptions(inspect: oldCollector.observe(), inspectable: true)).start()
        _ = await LogicActor(MachineLogic(machine: parent), id: "p", options: ActorOptions(inspect: newCollector.observe(), inspectable: true)).start()

        let oldActorEvents = oldCollector.recordedEvents().filter { $0.kind == .actor }.count
        let newActorEvents = newCollector.recordedEvents().filter { $0.kind == .actor }.count
        #expect(oldActorEvents == newActorEvents)   // root + child = 2 on both
        #expect(newActorEvents == 2)
    }
}
