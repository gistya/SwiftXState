import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State var session: LifeSession?
    @State var editorText: String = LifeRules.conway.jsonString

    var body: some View {
        Group {
            if let session {
                MainView(session: session, editorText: $editorText)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Create the session exactly once, after the environment (modelContext) is available. The
        // `== nil` guard means it never gets recreated — this is the long-lived observable object,
        // and it now gets the real modelContext so persistence (Save Snapshot) actually works.
        .task {
            if session == nil {
                session = LifeSession(modelContext: modelContext)
            }
        }
    }
}

#Preview {
    ContentView(session: LifeSession())
        .frame(width: 960, height: 720)
}
