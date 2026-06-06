#if SWIFTXSTATE_INSPECTOR_UI
import Testing
@testable import SwiftXState
@testable import SwiftXStateGraph
@testable import SwiftXStateInspectorUI

@Suite("Machine definition import")
struct MachineImportTests {

    @Test("imports a typed machine's own definitionJSON: initial value, context, graph")
    @MainActor
    func roundTripFromExportedDefinition() throws {
        struct Ctx: Sendable, Codable, Equatable { var count: Int }
        let machine = createMachine(MachineConfig<Ctx>(
            id: "traffic", initial: "green", context: Ctx(count: 7),
            states: [
                "green": StateNodeConfig(on: ["NEXT": .to("yellow")]),
                "yellow": StateNodeConfig(on: ["NEXT": .to("red")]),
                "red": StateNodeConfig(
                    initial: "wait",
                    states: [
                        "wait": StateNodeConfig(on: ["GO": .to("walk")]),
                        "walk": StateNodeConfig(type: .final),
                    ],
                    on: ["NEXT": .to("green")]
                ),
            ]
        ))
        let json = try machine.definitionJSON()

        // Event synthesis.
        let event = try MachineDefinitionImporter.makeEvent(fromJSON: json)
        #expect(event.kind == .actor)
        #expect(event.actor.machineId == "traffic")
        #expect(event.definitionJSON != nil)

        // Initial state value: root initial is the atomic "green".
        #expect(event.snapshot?.stateValue == .atomic("green"))

        // Graph parity: importing the JSON yields the same nodes/edges as building from the machine.
        let fromMachine = GraphModelBuilder.build(from: machine)
        let fromJSON = GraphModelBuilder.build(fromDefinitionJSON: json, machineID: "traffic")
        #expect(Set(fromJSON.nodes.map(\.id)) == Set(fromMachine.nodes.map(\.id)))
        let edgeKey: (GraphEdge) -> String = { "\($0.from)\u{1}\($0.to)\u{1}\($0.label)" }
        #expect(Set(fromJSON.edges.map(edgeKey)) == Set(fromMachine.edges.map(edgeKey)))
    }

    @Test("resolves a compound initial state into a nested value")
    func compoundInitial() throws {
        let json = """
        { "id": "m", "initial": "red",
          "states": {
            "green": {},
            "red": { "initial": "wait", "states": { "wait": {}, "walk": {} } }
          } }
        """
        let event = try MachineDefinitionImporter.makeEvent(fromJSON: json)
        #expect(event.snapshot?.stateValue == .compound(["red": .atomic("wait")]))
    }

    @Test("expands every region of a parallel state")
    func parallelInitial() throws {
        let json = """
        { "id": "p", "type": "parallel",
          "states": {
            "a": { "initial": "a1", "states": { "a1": {}, "a2": {} } },
            "b": { "initial": "b1", "states": { "b1": {}, "b2": {} } }
          } }
        """
        let event = try MachineDefinitionImporter.makeEvent(fromJSON: json)
        #expect(event.snapshot?.stateValue == .compound(["a": .atomic("a1"), "b": .atomic("b1")]))
    }

    @Test("extracts top-level context")
    func contextExtraction() throws {
        let json = """
        { "id": "m", "initial": "idle", "context": { "n": 42, "name": "x" },
          "states": { "idle": {} } }
        """
        let event = try MachineDefinitionImporter.makeEvent(fromJSON: json)
        #expect(event.snapshot?.context == .object(["n": .number(42), "name": .string("x")]))
    }

    @Test("uses fallback id when the definition has none")
    func fallbackID() throws {
        let json = #"{ "initial": "idle", "states": { "idle": {} } }"#
        let event = try MachineDefinitionImporter.makeEvent(fromJSON: json, fallbackID: "anon")
        #expect(event.actor.sessionID == "anon")
    }

    @Test("surfaces errors for empty and malformed input")
    func errors() {
        #expect(throws: MachineDefinitionImporter.ImportError.empty) {
            try MachineDefinitionImporter.makeEvent(fromJSON: "   ")
        }
        #expect(throws: MachineDefinitionImporter.ImportError.notAnObject) {
            try MachineDefinitionImporter.makeEvent(fromJSON: "[1,2,3]")
        }
        #expect(throws: (any Error).self) {
            try MachineDefinitionImporter.makeEvent(fromJSON: "{ not json")
        }
    }

    @Test("loadDefinition registers and selects the actor in the store")
    @MainActor
    func storeLoad() throws {
        let store = InspectorStore()
        let json = #"{ "id": "lights", "initial": "off", "states": { "off": {}, "on": {} } }"#
        let id = try store.loadDefinition(json: json)
        #expect(id == "lights")
        #expect(store.actors.count == 1)
        #expect(store.selectedSessionID == "lights")
        #expect(store.selectedActor?.stateValue == .atomic("off"))
        #expect(store.selectedActor?.definitionJSON != nil)

        // Loading again replaces the previous definition.
        let json2 = #"{ "id": "door", "initial": "closed", "states": { "closed": {}, "open": {} } }"#
        _ = try store.loadDefinition(json: json2)
        #expect(store.actors.count == 1)
        #expect(store.selectedSessionID == "door")
    }
}
#endif
