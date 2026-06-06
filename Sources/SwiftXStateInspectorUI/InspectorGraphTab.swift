#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI
import SwiftXState
import SwiftXStateGraph

/// Graphs the selected actor by parsing its `definitionJSON` and highlighting its live
/// `stateValue` — no typed `StateMachine`/`Actor` needed.
struct InspectorGraphTab: View {
    let actor: ActorEntry?
    var graphStyle: GraphStyle = .dark

    var body: some View {
        if let actor, let definition = actor.definitionJSON {
            StateGraphView(
                definitionJSON: definition,
                machineID: actor.machineID ?? actor.sessionID,
                stateValue: actor.stateValue
            )
            .graphStyle(graphStyle)
            .id(actor.sessionID) // rebuild the render core when switching actors
        } else {
            ContentUnavailableView_Compat(
                title: "No graph available",
                systemImage: "point.3.connected.trianglepath.dotted",
                message: actor == nil
                    ? "Select an actor to view its statechart."
                    : "This actor did not report a machine definition."
            )
        }
    }
}
#endif
