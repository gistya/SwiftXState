#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI
import SwiftXState

/// A full-width bottom drawer of actors that scrolls left→right. Sits *under* the main
/// view to make clear that the selected actor is what's being inspected. The "Actors" title
/// bar is always visible; clicking it (or the top-bar button) collapses/expands the strip.
struct InspectorActorBar: View {
    let store: InspectorStore
    @Binding var expanded: Bool
    @Environment(\.inspectorStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(style.divider).frame(height: 1)

            // Title bar — click to toggle.
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                Text("ACTORS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                Text("\(store.actors.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(style.secondaryText)
                Spacer()
            }
            .foregroundStyle(style.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.chrome)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } }

            if expanded {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 8) {
                        ForEach(store.actors) { actor in
                            chip(actor)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(height: 78)
                .background(style.panelBackground)
            }
        }
    }

    @ViewBuilder
    private func chip(_ actor: ActorEntry) -> some View {
        let selected = store.selectedSessionID == actor.sessionID
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                StatusDot(status: actor.status)
                Text(actor.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
            }
            if let value = actor.stateValue {
                StatePillView(stateValue: value)
            } else {
                Text(actor.subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 178, height: 58, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? style.rowSelectedBackground : style.chrome)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? style.accent : style.divider, lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onTapGesture { store.selectedSessionID = actor.sessionID }
    }
}
#endif
