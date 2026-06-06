import SwiftUI
import SwiftXState
import SwiftXStateGraph
import SwiftXStateInspectorUI

struct ContentView: View {
    /// One shared store: the paste pane writes definitions into it, the inspector reads from it.
    @State private var store = InspectorStore()

    private let style: InspectorStyle = .dark
    private let graphStyle: GraphStyle = .dark

    var body: some View {
        HSplitView {
            InspectorPasteView(store: store, initialText: SampleMachines.trafficLight)
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 600)

            MachineInspectorView(store: store, graphStyle: graphStyle)
                .frame(minWidth: 560, maxWidth: .infinity)
        }
        .inspectorStyle(style)
        .background(style.background)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .frame(width: 1100, height: 700)
}
