import SwiftUI
import SwiftData
import SwiftXStateSwiftData

@main
struct XConwayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .modelContainer(for: SwiftXStatePersistenceSchema.modelTypes)
    }
}
