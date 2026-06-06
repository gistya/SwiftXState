import Foundation
import SwiftXState
import SwiftXStateInspect
import Testing
@testable import SwiftXChessOpenings

@Suite("Machine definition export")
struct MachineDefinitionDumpTests {
    @Test("exports opening-move-tree inspector summary JSON")
    func openingTreeInspectorDefinition() throws {
        let json = try OpeningMoveTreeMachine.inspectorSummaryMachine().definitionJSON()
        #expect(json.contains("\"id\":\"opening-move-tree\""))
        #expect(json.contains("\"initial\":\"tracking\""))
        #expect(json.contains("SAN.*"))
        #expect(json.count < 800)
    }

    @Test("stately wire uses tracking state for opening tree snapshots")
    func openingTreeWireSnapshotValue() throws {
        let converter = StatelyWireConverter(machineDefinitions: [
            try InspectMachineRegistration(
                machineId: OpeningMoveTreeMachine.id,
                definitionJSON: OpeningMoveTreeMachine.inspectorSummaryMachine().definitionJSON(),
                wireStateValue: OpeningMoveTreeMachine.inspectorWireState
            ),
        ])
        let snapshot = InspectionSnapshot(
            actor: InspectionActorRef(sessionId: "tree", machineId: OpeningMoveTreeMachine.id),
            status: .active,
            value: "s999",
            stateValue: .atomic("s999"),
            tags: [],
            childCount: 0,
            context: .object(["nodeId": .string("s999"), "ply": .number(3)])
        )
        let event = InspectionEvent(
            kind: .snapshot,
            rootId: "tree",
            actor: InspectionActorRef(sessionId: "tree", machineId: OpeningMoveTreeMachine.id),
            event: InspectionEventDescription(type: "SAN.e4"),
            snapshot: snapshot
        )
        let payload = try #require(converter.wireData(for: event))
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let snapshotObject = object?["snapshot"] as? [String: Any]
        #expect(snapshotObject?["value"] as? String == OpeningMoveTreeMachine.inspectorWireState)
        #expect((snapshotObject?["context"] as? [String: Any])?["nodeId"] as? String == "s999")
    }

    @Test("opening tree microstep omits off-graph transition targets")
    func openingTreeWireMicrostepTransitions() throws {
        let converter = StatelyWireConverter(machineDefinitions: [
            try InspectMachineRegistration(
                machineId: OpeningMoveTreeMachine.id,
                definitionJSON: OpeningMoveTreeMachine.inspectorSummaryMachine().definitionJSON(),
                wireStateValue: OpeningMoveTreeMachine.inspectorWireState
            ),
        ])
        let snapshot = InspectionSnapshot(
            actor: InspectionActorRef(sessionId: "tree", machineId: OpeningMoveTreeMachine.id),
            status: .active,
            value: "s1",
            stateValue: .atomic("s42"),
            tags: [],
            childCount: 0,
            context: .object(["nodeId": .string("s42"), "ply": .number(1)])
        )
        let event = InspectionEvent(
            kind: .microstep,
            rootId: "tree",
            actor: InspectionActorRef(sessionId: "tree", machineId: OpeningMoveTreeMachine.id),
            event: InspectionEventDescription(type: "SAN.d4"),
            snapshot: snapshot,
            transitions: [
                InspectionTransitionInfo(
                    sourceId: "opening-move-tree.s1",
                    targetIds: ["opening-move-tree.s42"],
                    reenter: false
                ),
            ]
        )
        let payload = try #require(converter.wireData(for: event))
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        #expect(object?["_transitions"] == nil)
        #expect((object?["snapshot"] as? [String: Any])?["value"] as? String == "tracking")
    }

    @Test("attachInspect replays opening tree actor registration")
    func attachInspectReplaysActorRegistration() throws {
        let collector = InspectionCollector()
        let treeSession = try OpeningTreeSession()
        treeSession.attachInspect(collector.observe())

        let actorEvents = collector.recordedEvents().filter { $0.kind == .actor }
        #expect(actorEvents.count == 1)
        #expect(actorEvents[0].actor.machineId == OpeningMoveTreeMachine.id)
        #expect(actorEvents[0].snapshot != nil)
    }
}
