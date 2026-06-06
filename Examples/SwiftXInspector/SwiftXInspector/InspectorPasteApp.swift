import SwiftUI

/// A minimal app: paste an XState machine **definition** (JSON) on the left, watch it load into
/// the native SwiftXState Inspector on the right. No running machine, no WebSocket — the graph and
/// initial state are reconstructed straight from the pasted definition.
///
/// See README.md in this folder for how to wire these files into an Xcode project.
@main
struct InspectorPasteApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.titleBar)
    }
}
