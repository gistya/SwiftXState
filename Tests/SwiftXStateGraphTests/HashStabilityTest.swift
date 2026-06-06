#if SWIFTXSTATE_GRAPH_UI
import Testing
@testable import SwiftXState
@testable import SwiftXStateGraph

@Suite("Structure hash stability")
struct HashStabilityTest {
    @Test("rebuilding the model from the same definition JSON gives a stable structureHash")
    func stable() throws {
        let machine = createMachine(MachineConfig<Int>(
            id: "m", initial: "a", context: 0,
            states: [
                "a": StateNodeConfig(on: ["X": .to("b"), "Y": .to("c")]),
                "b": StateNodeConfig(on: ["Z": .to("a")]),
                "c": StateNodeConfig(type: .final),
            ]
        ))
        let json = try machine.definitionJSON()
        let h1 = GraphModelBuilder.build(fromDefinitionJSON: json, machineID: "m").structureHash
        let h2 = GraphModelBuilder.build(fromDefinitionJSON: json, machineID: "m").structureHash
        let h3 = GraphModelBuilder.build(fromDefinitionJSON: json, machineID: "m").structureHash
        #expect(h1 == h2)
        #expect(h2 == h3)
    }
}
#endif
