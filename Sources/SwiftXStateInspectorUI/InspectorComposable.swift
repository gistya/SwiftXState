#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI
import SwiftXState
import SwiftXStateGraph

// Public, composable building blocks of the inspector. `MachineInspectorView` is one arrangement
// of these; apps can lay them out however they like — e.g. animate each from its own screen edge
// for a custom "enter inspector mode" transition. All are driven by a shared `InspectorStore` and
// themed via `InspectorStyle`.

/// A slim info bar: the selected actor's name on the left, live actor/event counts on the right.
public struct InspectorInfoBar: View {
    private let store: InspectorStore
    @Environment(\.inspectorStyle) private var style

    public init(store: InspectorStore) { self.store = store }

    public var body: some View {
        HStack(spacing: 10) {
            if let actor = store.selectedActor {
                Text(actor.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.primaryText)
                if let value = actor.stateValue {
                    StatePillView(stateValue: value)
                }
            }
            Spacer()
            Text("\(store.actors.count) actors · \(store.feed.count) events")
                .font(.caption)
                .foregroundStyle(style.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(style.chrome)
    }
}

/// The State / Events / Sequence panel with its selector — the inspector's sidebar content.
public struct InspectorPanel: View {
    private let store: InspectorStore
    @Binding private var tab: InspectorTab
    @State private var eventsScopeToActor = false
    @Environment(\.inspectorStyle) private var style

    public init(store: InspectorStore, tab: Binding<InspectorTab>) {
        self.store = store
        self._tab = tab
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(InspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if tab == .events {
                    Toggle("This actor only", isOn: $eventsScopeToActor)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.caption)
                        .foregroundStyle(style.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Rectangle().fill(style.divider).frame(height: 1)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .background(style.panelBackground)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .state:
            InspectorStateTab(actor: store.selectedActor, store: store)
        case .events:
            InspectorEventsTab(store: store, filterSessionID: eventsScopeToActor ? store.selectedSessionID : nil)
        case .sequence:
            InspectorSequenceTab(store: store)
        }
    }
}

/// The live state graph for the store's selected actor.
public struct InspectorGraphView: View {
    private let store: InspectorStore
    private let graphStyle: GraphStyle

    public init(store: InspectorStore, graphStyle: GraphStyle = .dark) {
        self.store = store
        self.graphStyle = graphStyle
    }

    public var body: some View {
        InspectorGraphTab(actor: store.selectedActor, graphStyle: graphStyle)
    }
}

/// The full-width actors drawer: a horizontally scrolling strip of actor chips; tap to select.
/// `expanded` controls the collapsed/expanded strip.
public struct InspectorActorsDrawer: View {
    private let store: InspectorStore
    @Binding private var expanded: Bool

    public init(store: InspectorStore, expanded: Binding<Bool>) {
        self.store = store
        self._expanded = expanded
    }

    public var body: some View {
        InspectorActorBar(store: store, expanded: $expanded)
    }
}
#endif
