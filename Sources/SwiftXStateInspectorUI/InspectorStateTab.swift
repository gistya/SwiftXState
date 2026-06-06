#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI
import SwiftXState

/// The selected actor's current snapshot: its state value and context as JSON trees,
/// plus status / tags / output / error.
struct InspectorStateTab: View {
    let actor: ActorEntry?
    /// When set and the actor is simulatable (pasted/static), shows "Send events" controls.
    var store: InspectorStore? = nil
    @Environment(\.inspectorStyle) private var style

    var body: some View {
        if let actor, let snapshot = actor.latestSnapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(actor, snapshot)

                    if let store, store.isSimulatable(actor.sessionID) {
                        sendEventsSection(store: store, sessionID: actor.sessionID)
                    }

                    section("Value") {
                        JSONTreeView(snapshot.stateValue.toJSONValue(), defaultExpandedDepth: 4)
                    }

                    section("Context") {
                        JSONTreeView(snapshot.context, defaultExpandedDepth: 1)
                    }

                    if let output = snapshot.output {
                        section("Output") { JSONTreeView(output, defaultExpandedDepth: 2) }
                    }
                    if let error = snapshot.error {
                        section("Error") { JSONTreeView(error, defaultExpandedDepth: 2) }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(style.background)
        } else {
            ContentUnavailableView_Compat(
                title: "No snapshot yet",
                systemImage: "doc.text.magnifyingglass",
                message: "Select an actor and drive the machine to see its state."
            )
            .background(style.background)
        }
    }

    @ViewBuilder
    private func header(_ actor: ActorEntry, _ snapshot: InspectionSnapshot) -> some View {
        HStack(spacing: 10) {
            Text(actor.displayName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(style.primaryText)
            Text(snapshot.status.displayName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(style.background)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(statusColor(snapshot.status), in: Capsule())
            Spacer()
            if !snapshot.tags.isEmpty {
                Text(snapshot.tags.sorted().joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(style.secondaryText)
            }
        }
        StatePillView(stateValue: snapshot.stateValue)
    }

    /// Structural event controls: one button per event sendable from the current state.
    @ViewBuilder
    private func sendEventsSection(store: InspectorStore, sessionID: String) -> some View {
        let events = store.availableEvents(for: sessionID)
        VStack(alignment: .leading, spacing: 6) {
            Text("SEND EVENTS")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(style.secondaryText)
            if events.isEmpty {
                Text("No events available from this state — it's a dead end (or final).")
                    .font(.caption)
                    .foregroundStyle(style.secondaryText)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .leading)],
                    alignment: .leading, spacing: 8
                ) {
                    ForEach(events, id: \.self) { event in
                        Button {
                            store.send(event, to: sessionID)
                        } label: {
                            Text(event)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .lineLimit(1)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(style.accent)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.panelBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(style.secondaryText)
            content()
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(style.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func statusColor(_ status: SnapshotStatus) -> Color {
        switch status {
        case .active: return style.statusActive
        case .done: return style.statusDone
        case .error: return style.statusError
        case .stopped: return style.secondaryText
        }
    }
}

/// Minimal cross-version stand-in for `ContentUnavailableView`.
struct ContentUnavailableView_Compat: View {
    let title: String
    let systemImage: String
    let message: String
    @Environment(\.inspectorStyle) private var style

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(style.secondaryText)
            Text(title).font(.headline).foregroundStyle(style.primaryText)
            Text(message).font(.caption).foregroundStyle(style.secondaryText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
#endif
