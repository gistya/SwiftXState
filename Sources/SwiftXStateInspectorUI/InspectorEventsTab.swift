#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI
import SwiftXState

/// The chronological event feed: typed `ACTOR` / `EVENT` / `SNAPSHOT` rows with
/// timestamps. Snapshots show Value + Context trees; every row can expand to the raw
/// inspection event JSON.
struct InspectorEventsTab: View {
    let store: InspectorStore
    /// When non-nil, only events touching this actor are shown.
    let filterSessionID: String?

    @Environment(\.inspectorStyle) private var style
    @State private var rawExpanded: Set<Int> = []

    private var entries: [FeedEntry] {
        store.feed(for: filterSessionID).reversed()  // newest first
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    row(entry)
                    Divider().overlay(style.divider)
                }
            }
            .padding(.vertical, 4)
        }
        .background(style.background)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView_Compat(
                    title: "No events yet",
                    systemImage: "list.bullet.rectangle",
                    message: "Drive the machine to populate the event feed."
                )
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: FeedEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                EventKindBadge(kind: entry.kind)
                Spacer()
                Text(InspectorTime.string(entry.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(style.secondaryText)
            }

            title(entry)

            switch entry.kind {
            case .snapshot, .transition:
                if let snapshot = entry.snapshot {
                    HStack(alignment: .top, spacing: 18) {
                        labeledTree("Value", snapshot.stateValue.toJSONValue(), depth: 3)
                        labeledTree("Context", snapshot.context, depth: 1)
                    }
                }
            case .event:
                if let payload = entry.event.event?.payload, payload.isExpandable {
                    labeledTree("Payload", payload, depth: 1)
                }
            default:
                EmptyView()
            }

            rawDisclosure(entry)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func title(_ entry: FeedEntry) -> some View {
        let name = store.actor(entry.sessionID)?.displayName ?? entry.sessionID
        switch entry.kind {
        case .event:
            HStack(spacing: 6) {
                Text(entry.eventType ?? "(event)")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(style.primaryText)
                Text("→ \(name)")
                    .font(.system(size: 12))
                    .foregroundStyle(style.secondaryText)
            }
        case .snapshot, .transition:
            HStack(spacing: 8) {
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(style.primaryText)
                if let status = entry.snapshot?.status {
                    Text(status.displayName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(style.secondaryText)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(style.chrome, in: Capsule())
                }
            }
        case .actor:
            Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(style.primaryText)
        default:
            Text(name).font(.system(size: 13)).foregroundStyle(style.primaryText)
        }
    }

    @ViewBuilder
    private func labeledTree(_ label: String, _ value: JSONValue, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label + ":").font(.system(size: 11)).foregroundStyle(style.secondaryText)
            JSONTreeView(value, defaultExpandedDepth: depth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rawDisclosure(_ entry: FeedEntry) -> some View {
        let open = rawExpanded.contains(entry.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text("Inspection event")
                    .font(.system(size: 11))
            }
            .foregroundStyle(style.secondaryText)
            .contentShape(Rectangle())
            .onTapGesture {
                if open { rawExpanded.remove(entry.id) } else { rawExpanded.insert(entry.id) }
            }

            if open {
                JSONTreeView(entry.event.inspectorJSONValue(), defaultExpandedDepth: 1)
                    .padding(.leading, 4)
            }
        }
    }
}
#endif
