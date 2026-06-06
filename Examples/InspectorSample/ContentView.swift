import SwiftUI

struct ContentView: View {
    @State private var session = InspectSampleSession()

    var body: some View {
        NavigationSplitView {
            List(SampleDemoID.allCases, selection: $session.selectedDemo) { demo in
                VStack(alignment: .leading, spacing: 2) {
                    Text(demo.title)
                        .font(.headline)
                    Text(demo.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(demo)
            }
            .navigationTitle("Sample Machines")
        } detail: {
            DemoDetailView(session: session)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

private struct DemoDetailView: View {
    @Bindable var session: InspectSampleSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                stateCard
                eventsCard
                inspectorCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(session.selectedDemo.title)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.selectedDemo.title)
                .font(.largeTitle.bold())
            Text("Ported from \(session.selectedDemo.source)")
                .foregroundStyle(.secondary)
        }
    }

    private var stateCard: some View {
        GroupBox("Current State") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Value") {
                    Text(session.stateLine)
                        .font(.body.monospaced())
                }
                LabeledContent("Context") {
                    Text(session.contextLine)
                        .font(.body.monospaced())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var eventsCard: some View {
        GroupBox("Send Events") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(session.eventButtons) { button in
                    Button(button.label) {
                        button.action()
                        session.refresh()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inspectorCard: some View {
        GroupBox("Stately Inspector") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Status") {
                    Text(session.connectionStatus)
                }
                LabeledContent("WebSocket") {
                    Text(session.inspectorEndpoint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Text("Run `npm install && npm run relay` in Scripts/relay, then open the session URL printed in the terminal (`https://stately.ai/registry/inspect/…`). Do not use the generic `stately.ai/inspect` landing page. Use the SX_XS_Visualizer_POC Xcode target for network entitlements.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}