import SwiftUI
import SwiftXState
import SwiftXStateGraph
import SwiftXStateInspectorUI

@main
struct SwiftXChessApp: App {
    @State private var bootstrap = AppBootstrap()

    var body: some Scene {
        WindowGroup {
            BootstrappedView(bootstrap: bootstrap) { model in
                ContentView(session: model.session, store: model.store)
            }
            .task {
                await bootstrap.start()
            }
        }
#if canImport(AppKit)
        Window("Inspector", id: "state-graph") {
            BootstrappedView(bootstrap: bootstrap) { model in
                InspectorWindow(
                    store: model.store,
                    hasSession: model.session != nil
                )
            }
        }
        .defaultSize(width: 1180, height: 820)
#endif
    }
}

@MainActor
@Observable
final class AppBootstrap {
    private(set) var phase: Phase = .loading

    enum Phase {
        case loading
        case ready(SessionModel)
        case failed(Error)
    }

    func start() async {
        if case .ready = phase { return }

        do {
            let model = try await SessionModel.bootstrap()
            phase = .ready(model)
        } catch {
            phase = .failed(error)
        }
    }
}

struct BootstrappedView<Content: View>: View {
    let bootstrap: AppBootstrap

    let content: (SessionModel) -> Content

    var body: some View {
        switch bootstrap.phase {
        case .loading:
            ProgressView("Loading…")

        case .ready(let model):
            content(model)

        case .failed(let error):
            VStack {
                Text("Couldn’t start app")
                Text(error.localizedDescription)
            }
        }
    }
}
