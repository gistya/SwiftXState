import SwiftUI
import SwiftXStateGraph
import SwiftXStateInspectorUI

struct InspectorWindow: View {
    let store: InspectorStore
    let hasSession: Bool

    /// Dark graph theme + a custom layout that renders the board-inspector's 64 square
    /// states as an actual 8×8 board (other machines stay auto-laid-out).
    private var graphStyle: GraphStyle {
        var style = GraphStyle.dark
        style.nodeLayoutOverride = BoardInspectorMachine.gridLayoutOverride()
        return style
    }

    var body: some View {
        if hasSession {
            MachineInspectorView(store: store, graphStyle: graphStyle)
                .inspectorStyle(.dark)
        } else {
            ContentUnavailableView(
                "Inspector unavailable",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("The chess session could not be started.")
            )
        }
    }
}
