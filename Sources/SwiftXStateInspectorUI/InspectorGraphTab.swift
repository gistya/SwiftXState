#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI
import SwiftXState
import SwiftXStateGraph

/// Graphs the selected reactor by parsing its `definitionJSON` and highlighting its live
/// `stateValue` — no typed `StateMachine`/`Reactor` needed.
struct InspectorGraphTab: View {
    let reactor:ReactorEntry?
    var graphStyle: GraphStyle = .dark

    var body: some View {
        if let reactor, let definition = reactor.definitionJSON {
            StateGraphView(
                definitionJSON: definition,
                machineID: reactor.machineID ?? reactor.sessionID,
                stateValue: reactor.stateValue
            )
            .graphStyle(graphStyle)
            .id(reactor.sessionID) // rebuild the render core when switching reactors
        } else {
            ContentUnavailableView_Compat(
                title: "No graph available",
                systemImage: "point.3.connected.trianglepath.dotted",
                message: reactor == nil
                    ? "Select an reactor to view its statechart."
                    : "This reactor did not report a machine definition."
            )
        }
    }
}
#endif
