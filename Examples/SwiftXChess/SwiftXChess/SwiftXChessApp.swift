import SwiftUI
import SwiftXState
import SwiftXStateGraph
import SwiftXStateInspectorUI

@main
struct SwiftXChessApp: App {
    /// One shared inspector store, fed by the shared session's actors. The main window's
    /// board drives the session; the Inspector window observes the same stream live.
    @State private var store: InspectorStore
    /// One shared session for the whole app.
    @State private var session: DistributedChessSession?

    init() {
        let store = InspectorStore()
        _store = State(initialValue: store)
        // Route every inspection event into the store so the Inspector window is live.
        _session = State(initialValue: try? DistributedChessSession(extraInspect: store.observe()))
    }

    var body: some Scene {
        #if canImport(AppKit)
        WindowGroup {
            ContentView(session: session)
        }

        // A native Stately-style inspector over the shared session.
        Window("Inspector", id: "state-graph") {
            InspectorWindow(store: store, hasSession: session != nil)
                .frame(minWidth: 760, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 820)
        #endif
        #if os(iOS)
        // iPad/iPhone: a single window. The inspector lives inside ContentView (a tab in
        // layout A, a sheet in layout B) rather than stacked into the window group.
        WindowGroup {
            ContentView(session: session, store: store)
        }
        #endif
    }
}

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
