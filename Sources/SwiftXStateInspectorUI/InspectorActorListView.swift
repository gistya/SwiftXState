#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI
import SwiftXState

/// The actor selector sidebar: a hierarchical list of every actor on the stream, each
/// with a state pill and status dot. Tapping selects it (drives the Graph/State tabs).
struct InspectorActorListView: View {
    let store: InspectorStore
    @Environment(\.inspectorStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ACTORS")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(style.secondaryText)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if store.actors.isEmpty {
                Text("Waiting for actors…")
                    .font(.system(size: 12))
                    .foregroundStyle(style.secondaryText)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.actorTree(), id: \.actor.id) { item in
                            row(item.actor, depth: item.depth)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(style.panelBackground)
    }

    @ViewBuilder
    private func row(_ actor: ActorEntry, depth: Int) -> some View {
        let selected = store.selectedSessionID == actor.sessionID
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusDot(status: actor.status)
                Text(actor.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if let value = actor.stateValue {
                StatePillView(stateValue: value)
            } else if actor.machineID != nil {
                Text(actor.subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .padding(.leading, CGFloat(depth) * 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? style.rowSelectedBackground : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.selectedSessionID = actor.sessionID }
    }
}
#endif
