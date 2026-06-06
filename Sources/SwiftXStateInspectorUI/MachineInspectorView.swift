#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI
import SwiftXState
import SwiftXStateGraph
#if canImport(AppKit)
import AppKit
#endif

/// Panels shown inside the inspector sidebar (the live graph is the always-on main canvas).
public enum InspectorTab: String, CaseIterable, Sendable {
    case state = "State"
    case events = "Events"
    case sequence = "Sequence"
}

/// A native, Stately-Inspector-style view over an `InspectorStore`.
///
/// Three real regions (no overlapping panes):
/// - a **bottom drawer** of actors (full width, scrolls left→right) — the selected actor is
///   what everything else inspects;
/// - a resizable left **sidebar** with a panel selector (State / Events / Sequence) and the
///   selected panel's content;
/// - the live **graph** for the selected actor as the main canvas.
///
/// The top bar offers show/hide sidebar, **Maximize** / **Minimize** sidebar, and a toggle for
/// the actors drawer.
///
/// Wire `store.observe()` into your actors' `ActorOptions(inspect:)`; this view renders
/// whatever the store has accumulated.
@MainActor
public struct MachineInspectorView: View {
    private let store: InspectorStore
    private let graphStyle: GraphStyle
    @Environment(\.inspectorStyle) private var style

    @State private var tab: InspectorTab = .state
    @State private var showSidebar = true
    @State private var actorsExpanded = true
    @State private var sidebarWidth: CGFloat = 360
    @State private var dragStartWidth: CGFloat?

    private let minSidebarWidth: CGFloat = 320

    public init(store: InspectorStore, graphStyle: GraphStyle = .dark) {
        self.store = store
        self.graphStyle = graphStyle
    }

    public var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar(total: geo.size.width)
                Rectangle().fill(style.divider).frame(height: 1)

                // Main row: sidebar and graph are two side-by-side panes (no overlap).
                HStack(spacing: 0) {
                    if showSidebar {
                        sidebar
                            .frame(width: clampedSidebarWidth(total: geo.size.width))
                        resizeHandle(total: geo.size.width)
                    }
                    InspectorGraphTab(actor: store.selectedActor, graphStyle: graphStyle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                // Bottom drawer: actors across the full width.
                InspectorActorBar(store: store, expanded: $actorsExpanded)
            }
        }
        .background(style.background)
    }

    private func clampedSidebarWidth(total: CGFloat) -> CGFloat {
        let maxWidth = max(minSidebarWidth, total - 4)
        return min(max(sidebarWidth, minSidebarWidth), maxWidth)
    }

    // MARK: Top bar

    private func topBar(total: CGFloat) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: $showSidebar) { Label("Inspector", systemImage: "sidebar.leading") }
                .toggleStyle(.button)

            Button {
                showSidebar = true
                withAnimation(.easeInOut(duration: 0.2)) { sidebarWidth = max(minSidebarWidth, total - 4) }
            } label: { Label("Maximize", systemImage: "arrow.up.left.and.arrow.down.right") }
                .help("Maximize sidebar")

            Button {
                showSidebar = true
                withAnimation(.easeInOut(duration: 0.2)) { sidebarWidth = minSidebarWidth }
            } label: { Label("Minimize", systemImage: "arrow.down.right.and.arrow.up.left") }
                .help("Minimize sidebar")

            Toggle(isOn: $actorsExpanded) { Label("Actors", systemImage: "rectangle.bottomthird.inset.filled") }
                .toggleStyle(.button)
                .help("Show/hide the actors drawer")

            Spacer()

            Text("\(store.actors.count) actors · \(store.feed.count) events")
                .font(.caption)
                .foregroundStyle(style.secondaryText)
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(style.chrome)
    }

    // MARK: Sidebar (panel tabs + content) — the composable `InspectorPanel`.

    private var sidebar: some View {
        InspectorPanel(store: store, tab: $tab)
    }

    // MARK: Resize handle

    private func resizeHandle(total: CGFloat) -> some View {
        Rectangle()
            .fill(style.divider)
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragStartWidth == nil { dragStartWidth = clampedSidebarWidth(total: total) }
                                let proposed = (dragStartWidth ?? sidebarWidth) + value.translation.width
                                sidebarWidth = min(max(proposed, minSidebarWidth), max(minSidebarWidth, total - 4))
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
                    #if os(macOS)
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    #endif
            )
    }
}
#endif
