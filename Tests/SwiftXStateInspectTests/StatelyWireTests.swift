import Foundation
import Testing
@testable import SwiftXState
@testable import SwiftXStateInspect

@Suite("Stately wire protocol")
struct StatelyWireTests {
    private var trafficMachine: StateMachine<EmptyContext> {
        createMachine(MachineConfig(
            id: "trafficLight",
            initial: "green",
            context: EmptyContext(),
            states: [
                "green": StateNodeConfig(on: ["NEXT": .to("yellow")]),
                "yellow": StateNodeConfig(on: ["NEXT": .to("red")]),
                "red": StateNodeConfig(type: .final),
            ]
        ))
    }

    @Test("machine definition exports XState-compatible JSON")
    func machineDefinitionJSON() throws {
        let json = try trafficMachine.definitionJSON()
        let data = Data(json.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["id"] as? String == "trafficLight")
        #expect(object?["initial"] as? String == "green")

        let states = object?["states"] as? [String: Any]
        let green = states?["green"] as? [String: Any]
        let on = green?["on"] as? [String: Any]
        #expect(on?["NEXT"] as? String == "yellow")
    }

    @Test("stately converter uses inline definitionJSON on actor events")
    func actorEventWithInlineDefinition() throws {
        let definition = try trafficMachine.definitionJSON()
        let converter = StatelyWireConverter()

        let event = InspectionEvent.actor(
            rootId: "trafficLight",
            actor: InspectionActorRef(sessionId: "child", machineId: "trafficLight"),
            definitionJSON: definition
        )

        let wire = try #require(converter.statelyEvent(for: event))
        #expect(wire.definition == definition)
    }

    @Test("stately converter emits actor event with machine definition")
    func actorEventWithDefinition() throws {
        let definition = try trafficMachine.definitionJSON()
        let converter = StatelyWireConverter(machineDefinitions: [
            InspectMachineRegistration(machineId: "trafficLight", definitionJSON: definition),
        ])

        let event = InspectionEvent.actor(
            rootId: "trafficLight",
            actor: InspectionActorRef(sessionId: "trafficLight", machineId: "trafficLight")
        )

        let wire = try #require(converter.statelyEvent(for: event))
        #expect(wire.type == "@xstate.actor")
        #expect(wire.name == "trafficLight")
        #expect(wire.sessionId == "trafficLight")
        #expect(wire.definition == definition)
        #expect(wire.version == StatelyWireConverter.protocolVersion)
    }

    @Test("stately converter emits transition events")
    func transitionWireEvent() throws {
        let converter = StatelyWireConverter()
        let snapshot = InspectionSnapshot(
            actor: InspectionActorRef(sessionId: "a"),
            status: .active,
            value: "yellow",
            stateValue: .atomic("yellow"),
            tags: [],
            childCount: 0
        )

        let transition = InspectionEvent(
            kind: .transition,
            rootId: "a",
            actor: InspectionActorRef(sessionId: "a"),
            event: InspectionEventDescription(type: "NEXT"),
            snapshot: snapshot
        )

        let wire = try #require(converter.statelyEvent(for: transition))
        #expect(wire.type == "@xstate.transition")
        #expect(wire.event != nil)
        #expect(wire.snapshot != nil)
    }

    @Test("stately converter emits action events")
    func actionWireEvent() throws {
        let converter = StatelyWireConverter()
        let action = InspectionEvent.action(
            rootId: "a",
            actor: InspectionActorRef(sessionId: "a"),
            actionType: "xstate.assign",
            triggeringEvent: Event("NEXT")
        )

        let wire = try #require(converter.statelyEvent(for: action))
        #expect(wire.type == "@xstate.action")
        #expect(wire.action?.type == "xstate.assign")
    }

    @Test("stately converter emits microstep events with transitions")
    func microstepWireEvent() throws {
        let converter = StatelyWireConverter()
        let machine = trafficMachine
        let (initial, _) = initialTransition(machine)
        let (next, _, microsteps) = macrostep(snapshot: initial, event: Event("NEXT"), isInitial: false)
        let step = try #require(microsteps.first)

        let event = InspectionEvent.microstep(
            rootId: "trafficLight",
            actor: InspectionActorRef(sessionId: "trafficLight", machineId: "trafficLight"),
            triggeringEvent: step.event,
            machineSnapshot: next,
            transitions: step.transitions
        )

        let wire = try #require(converter.statelyEvent(for: event))
        let payload = try #require(converter.wireData(for: event))
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]

        #expect(wire.type == "@xstate.microstep")
        #expect(wire.transitions != nil)
        #expect(object?["_transitions"] != nil)
        #expect((object?["snapshot"] as? [String: Any])?["value"] as? String == "yellow")
    }

    @Test("actor start registers before init event on the wire")
    func actorStartInspectionOrder() async throws {
        let transport = MockInspectTransport(policy: .localhostOnly())
        let definition = try trafficMachine.definitionJSON()
        let bridge = InspectBridge(
            transport: transport,
            configuration: InspectClientConfiguration(
                policy: .localhostOnly(),
                endpoint: InspectEndpoint(host: "127.0.0.1", port: 8080),
                enablement: InspectEnablement(requiresDebugBuild: false, userOptIn: true),
                wireFormat: .stately,
                machineDefinitions: [
                    InspectMachineRegistration(machineId: "trafficLight", definitionJSON: definition),
                ]
            )
        )
        bridge.start()

        _ = createActor(trafficMachine, inspect: bridge.observe()).start()

        // Wait until the actor registration and the resulting snapshot have both
        // been published, rather than guessing a fixed delay.
        await waitUntil {
            let recorded = await transport.recordedMessages()
            let kinds = recorded.compactMap { message -> String? in
                guard let data = message.statelyPayload else { return nil }
                return try? JSONDecoder().decode(StatelyWireEvent.self, from: data).type
            }
            return kinds.contains("@xstate.actor") && kinds.contains("@xstate.snapshot")
        }

        let messages = await transport.recordedMessages()
        let types = try messages.compactMap { message -> String? in
            guard let data = message.statelyPayload else { return nil }
            return try JSONDecoder().decode(StatelyWireEvent.self, from: data).type
        }

        let actorIndex = try #require(types.firstIndex(of: "@xstate.actor"))
        if let eventIndex = types.firstIndex(of: "@xstate.event") {
            #expect(actorIndex < eventIndex)
        }
        if let snapshotIndex = types.firstIndex(of: "@xstate.snapshot") {
            #expect(actorIndex < snapshotIndex)
        }

        await bridge.stop()
    }

    @Test("stately bridge publishes raw JSON over mock transport")
    func bridgePublishesStatelyEvents() async throws {
        let transport = MockInspectTransport(policy: .localhostOnly())
        let definition = try trafficMachine.definitionJSON()
        let bridge = InspectBridge(
            transport: transport,
            configuration: InspectClientConfiguration(
                policy: .localhostOnly(),
                endpoint: InspectEndpoint(host: "127.0.0.1", port: 8080),
                enablement: InspectEnablement(requiresDebugBuild: false, userOptIn: true),
                wireFormat: .stately,
                machineDefinitions: [
                    InspectMachineRegistration(machineId: "trafficLight", definitionJSON: definition),
                ]
            )
        )
        bridge.start()

        let collector = InspectionCollector()
        let actor = createActor(
            trafficMachine,
            inspect: { event in
                collector.observe()(event)
                bridge.observe()(event)
            }
        ).start()

        actor.send(Event("NEXT"))

        // Wait until the actor, transition/microstep, and snapshot events have
        // all been published over the transport.
        await waitUntil {
            let recorded = await transport.recordedMessages()
            let kinds = Set(recorded.compactMap { message -> String? in
                guard let data = message.statelyPayload else { return nil }
                return try? JSONDecoder().decode(StatelyWireEvent.self, from: data).type
            })
            return kinds.contains("@xstate.actor")
                && (kinds.contains("@xstate.transition") || kinds.contains("@xstate.microstep"))
                && kinds.contains("@xstate.snapshot")
        }

        let messages = await transport.recordedMessages()
        #expect(messages.count >= 2)
        #expect(messages.allSatisfy { $0.type == "stately.event" })

        let payloads = try messages.compactMap(\.statelyPayload).map {
            try JSONDecoder().decode(StatelyWireEvent.self, from: $0)
        }
        let types = Set(payloads.map(\.type))
        #expect(types.contains("@xstate.actor"))
        #expect(types.contains("@xstate.transition") || types.contains("@xstate.microstep"))
        #expect(types.contains("@xstate.snapshot"))

        await bridge.stop()
    }

    @Test("snapshot wire value uses nested state object")
    func snapshotValueEncoding() throws {
        let converter = StatelyWireConverter()
        let snapshot = InspectionSnapshot(
            actor: InspectionActorRef(sessionId: "light"),
            status: .active,
            value: "red, wait",
            stateValue: .compound(["red": .atomic("wait")]),
            tags: ["slow"],
            childCount: 0
        )
        let event = InspectionEvent(
            kind: .snapshot,
            rootId: "light",
            actor: InspectionActorRef(sessionId: "light"),
            event: InspectionEventDescription(type: "NEXT"),
            snapshot: snapshot
        )

        let wire = try #require(converter.statelyEvent(for: event))
        let payload = try #require(converter.wireData(for: event))
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let snapshotObject = object?["snapshot"] as? [String: Any]
        let value = snapshotObject?["value"] as? [String: Any]

        #expect(wire.type == "@xstate.snapshot")
        #expect(snapshotObject?["status"] as? String == "active")
        #expect(snapshotObject?["context"] != nil)
        #expect(snapshotObject?["children"] != nil)
        #expect(snapshotObject?["historyValue"] != nil)
        #expect(value?["red"] as? String == "wait")
        #expect((snapshotObject?["tags"] as? [String])?.contains("slow") == true)
    }

    @Test("snapshot wire matches XState inspect shape")
    func snapshotWireShape() throws {
        let converter = StatelyWireConverter()
        let snapshot = InspectionSnapshot(
            actor: InspectionActorRef(sessionId: "counter"),
            status: .active,
            value: "ready",
            stateValue: .atomic("ready"),
            tags: [],
            childCount: 0,
            context: .object(["count": .number(2)])
        )
        let event = InspectionEvent(
            kind: .snapshot,
            rootId: "counter",
            actor: InspectionActorRef(sessionId: "counter"),
            event: InspectionEventDescription(type: "increase"),
            snapshot: snapshot
        )

        let payload = try #require(converter.wireData(for: event))
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let snapshotObject = try #require(object?["snapshot"] as? [String: Any])

        #expect(snapshotObject["status"] as? String == "active")
        #expect(snapshotObject["value"] as? String == "ready")
        #expect((snapshotObject["context"] as? [String: Any])?["count"] as? Double == 2)
        #expect((snapshotObject["children"] as? [String: Any])?.isEmpty == true)
        #expect((snapshotObject["historyValue"] as? [String: Any])?.isEmpty == true)
        #expect((snapshotObject["tags"] as? [String])?.isEmpty == true)
        #expect(snapshotObject["output"] is NSNull)
        #expect(snapshotObject["error"] is NSNull)
    }
}