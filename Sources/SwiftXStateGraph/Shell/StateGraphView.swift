import SwiftUI

/// Renders a statechart from a `GraphModel` (or an exported definition) plus an optional
/// live `StateValue` for highlighting — without requiring a typed `Actor`/`ResolvedMachine`.
/// This is what the inspector uses to graph any actor from its `definitionJSON`.
@MainActor
public struct StateGraphView: View {
    private let model: GraphModel
    private let stateValue: StateValue?
    @State private var render: GraphRenderModel

    public init(model: GraphModel, stateValue: StateValue? = nil) {
        self.model = model
        self.stateValue = stateValue
        let render = GraphRenderModel(model: model)
        render.setActive(stateValue: stateValue)
        _render = State(initialValue: render)
    }

    /// Builds the model from an exported machine definition (see `ResolvedMachine.definitionJSON()`).
    public init(definitionJSON: String, machineID: String, stateValue: StateValue? = nil) {
        self.init(model: GraphModelBuilder.build(fromDefinitionJSON: definitionJSON, machineID: machineID),
                  stateValue: stateValue)
    }

    public var body: some View {
        GraphRenderView(render: render)
            .onChange(of: model.structureHash) { _, _ in
                render.setModel(model)
                render.setActive(stateValue: stateValue)
            }
            .onChange(of: stateValue) { _, newValue in
                render.setActive(stateValue: newValue)
            }
    }
}
