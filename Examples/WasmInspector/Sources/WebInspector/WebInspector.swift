import JavaScriptKit
import JavaScriptEventLoop
import SwiftXState
import SwiftXStateInspectorCore
// Re-exported so consumers (and the demo) can name `StateGraph.TextMode` via `import WebInspector`.
@_exported import WebGPUGraph

/// The browser inspector toolkit. Give it a container element id and a `WebInspectorStore` (fed from
/// any actor's inspection stream) and it renders an actor sidebar + State / Events / Sequence / Graph
/// tabs. The Graph tab reuses the GPU `WebGPUGraph` renderer for the selected actor's definition.
///
/// ```swift
/// let store = WebInspectorStore()
/// _ = createActor(machine, ActorOptions(inspect: store.observe())).start()
/// WebInspector.mount(containerId: "app", store: store)
/// ```
@MainActor
public enum WebInspector {
    public static func mount(containerId: String, store: WebInspectorStore, graphTextMode: StateGraph.TextMode = .msdf) {
        let view = InspectorView(containerId: containerId, store: store, graphTextMode: graphTextMode)
        view.build()
        // Strong capture on purpose: the view must outlive `mount`, and the store lives for the life
        // of the page, so this keeps the view alive too (no other owner exists).
        store.onChange = { view.render() }
        view.render()
    }
}

@MainActor
final class InspectorView {
    enum Tab: String, CaseIterable { case state = "State", events = "Events", sequence = "Sequence", graph = "Graph" }

    private let store: WebInspectorStore
    private let containerId: String
    private let graphTextMode: StateGraph.TextMode
    private var currentTab: Tab = .state

    // Persistent DOM regions (rebuilt children on render, except the graph canvas which is kept alive).
    private var actorList = JSValue.undefined
    private var panels: [Tab: JSValue] = [:]
    private var tabButtons: [Tab: JSValue] = [:]

    private let graphCanvasId = "insp-graph-canvas"
    private var graphStartedForDefinition: String?

    init(containerId: String, store: WebInspectorStore, graphTextMode: StateGraph.TextMode) {
        self.containerId = containerId
        self.store = store
        self.graphTextMode = graphTextMode
    }

    // MARK: Build (once)

    func build() {
        DOM.injectStyle(Self.css)

        let host = DOM.byId(containerId)
        DOM.removeAllChildren(host)

        let root = DOM.el("div", "insp-root")

        let header = DOM.el("div", "insp-header")
        DOM.append(header, DOM.el("span", "insp-logo", text: "◆"))
        DOM.append(header, DOM.el("span", "insp-title", text: "SwiftXState Inspector"))
        DOM.append(header, DOM.el("span", "insp-sub", text: "Swift → WebAssembly"))
        DOM.append(root, header)

        let body = DOM.el("div", "insp-body")

        // Sidebar.
        let sidebar = DOM.el("div", "insp-sidebar")
        DOM.append(sidebar, DOM.el("div", "insp-section-title", text: "ACTORS"))
        actorList = DOM.el("div", "insp-actor-list")
        DOM.append(sidebar, actorList)
        DOM.append(body, sidebar)

        // Main: tab bar + content.
        let main = DOM.el("div", "insp-main")
        let tabBar = DOM.el("div", "insp-tabs")
        for tab in Tab.allCases {
            let btn = DOM.el("button", "insp-tab", text: tab.rawValue)
            DOM.onClick(btn) { [weak self] in
                self?.currentTab = tab
                self?.render()
            }
            tabButtons[tab] = btn
            DOM.append(tabBar, btn)
        }
        DOM.append(main, tabBar)

        let content = DOM.el("div", "insp-content")
        for tab in Tab.allCases {
            let panel = DOM.el("div", "insp-panel")
            if tab == .graph {
                // Persistent canvas — never torn down, so WebGPU state survives tab switches.
                let canvas = DOM.el("canvas", "insp-graph")
                canvas.id = .string(graphCanvasId)
                canvas.width = .number(760)
                canvas.height = .number(460)
                DOM.append(panel, canvas)
            }
            panels[tab] = panel
            DOM.append(content, panel)
        }
        DOM.append(main, content)
        DOM.append(body, main)

        DOM.append(root, body)
        DOM.append(host, root)
    }

    // MARK: Render (on every change)

    func render() {
        renderActorList()
        renderTabBar()
        renderPanels()
    }

    private func renderActorList() {
        DOM.removeAllChildren(actorList)
        let selected = store.state.selectedSessionID
        for (entry, depth) in store.state.actorTree() {
            let row = DOM.el("div", entry.sessionID == selected ? "insp-actor insp-actor-sel" : "insp-actor")
            DOM.style(row, "padding-left:\(8 + depth * 14)px")

            let dot = DOM.el("span", "insp-dot insp-dot-\(statusName(entry.status))")
            DOM.append(row, dot)

            let name = DOM.el("span", "insp-actor-name", text: entry.displayName)
            DOM.append(row, name)

            if let value = entry.stateValue?.description, !value.isEmpty {
                DOM.append(row, DOM.el("span", "insp-pill", text: value))
            }

            let sid = entry.sessionID
            DOM.onClick(row) { [weak self] in self?.store.select(sid) }
            DOM.append(actorList, row)
        }
        if store.state.actors.isEmpty {
            DOM.append(actorList, DOM.el("div", "insp-empty", text: "Waiting for actors…"))
        }
    }

    private func renderTabBar() {
        for (tab, btn) in tabButtons {
            btn.className = .string(tab == currentTab ? "insp-tab insp-tab-sel" : "insp-tab")
        }
    }

    private func renderPanels() {
        for (tab, panel) in panels {
            DOM.style(panel, tab == currentTab ? "display:block" : "display:none")
        }
        switch currentTab {
        case .state: renderStatePanel()
        case .events: renderEventsPanel()
        case .sequence: renderSequencePanel()
        case .graph: updateGraphPanel()
        }
    }

    private func renderStatePanel() {
        let panel = panels[.state]!
        DOM.removeAllChildren(panel)
        guard let actor = store.state.selectedActor else {
            DOM.append(panel, DOM.el("div", "insp-empty", text: "Select an actor."))
            return
        }

        let head = DOM.el("div", "insp-state-head")
        DOM.append(head, DOM.el("span", "insp-state-name", text: actor.displayName))
        DOM.append(head, DOM.el("span", "insp-tag insp-tag-\(statusName(actor.status))", text: statusName(actor.status)))
        DOM.append(panel, head)

        DOM.append(panel, DOM.el("div", "insp-section-title", text: "VALUE"))
        let value = actor.stateValue?.description ?? "—"
        DOM.append(panel, DOM.el("div", "insp-value", text: value))

        // Drivable events for statically-loaded (pasted/simulated) actors.
        let events = store.state.availableEvents(for: actor.sessionID)
        if !events.isEmpty {
            let row = DOM.el("div", "insp-event-buttons")
            for name in events {
                let btn = DOM.el("button", "insp-send", text: name)
                let sid = actor.sessionID
                DOM.onClick(btn) { [weak self] in self?.store.send(name, to: sid) }
                DOM.append(row, btn)
            }
            DOM.append(panel, row)
        }

        DOM.append(panel, DOM.el("div", "insp-section-title", text: "CONTEXT"))
        let context = actor.contextJSON ?? .object([:])
        DOM.append(panel, JSONTreeDOM.render(context, expandedDepth: 2))
    }

    private func renderEventsPanel() {
        let panel = panels[.events]!
        DOM.removeAllChildren(panel)
        let feed = store.state.feed(for: store.state.selectedSessionID)
        if feed.isEmpty {
            DOM.append(panel, DOM.el("div", "insp-empty", text: "No events yet."))
            return
        }
        // Newest first, capped for the DOM.
        for entry in feed.suffix(300).reversed() {
            let details = DOM.el("details", "insp-feed-row")
            let summary = DOM.el("summary", "insp-feed-summary")
            DOM.append(summary, DOM.el("span", "insp-kind insp-kind-\(kindName(entry.kind))", text: kindName(entry.kind).uppercased()))
            let label = entry.eventType ?? entry.snapshot?.stateValue.description ?? entry.sessionID
            DOM.append(summary, DOM.el("span", "insp-feed-label", text: label))
            DOM.append(summary, DOM.el("span", "insp-feed-time", text: String(format: "%.0f", entry.timestamp)))
            DOM.append(details, summary)
            DOM.append(details, JSONTreeDOM.render(entry.event.inspectorJSONValue(), expandedDepth: 1))
            DOM.append(panel, details)
        }
    }

    private func renderSequencePanel() {
        let panel = panels[.sequence]!
        DOM.removeAllChildren(panel)
        let feed = store.state.feed
        let arrows = feed.filter { $0.kind == .event }
        if arrows.isEmpty {
            DOM.append(panel, DOM.el("div", "insp-empty", text: "No events to sequence yet."))
            return
        }
        for entry in arrows.suffix(200) {
            let row = DOM.el("div", "insp-seq-row")
            let from = entry.sourceSessionID ?? "·"
            DOM.append(row, DOM.el("span", "insp-seq-actor", text: from))
            DOM.append(row, DOM.el("span", "insp-seq-arrow", text: "→"))
            DOM.append(row, DOM.el("span", "insp-seq-actor", text: entry.sessionID))
            DOM.append(row, DOM.el("span", "insp-seq-event", text: entry.eventType ?? ""))
            DOM.append(panel, row)
        }
    }

    private func updateGraphPanel() {
        guard let actor = store.state.selectedActor, let definition = actor.definitionJSON else {
            return
        }
        if graphStartedForDefinition != definition {
            graphStartedForDefinition = definition
            let canvasId = graphCanvasId
            let mode = graphTextMode
            Task { @MainActor in
                await StateGraph.start(canvasElementId: canvasId, definitionJSON: definition, textMode: mode) { [weak self] tapped in
                    // Tapping a node could drive a simulated actor; left as a hook for now.
                    _ = self
                    _ = tapped
                }
                if let value = actor.stateValue?.description { StateGraph.setActiveState(value) }
            }
        } else if let value = actor.stateValue?.description {
            StateGraph.setActiveState(value)
        }
    }

    // MARK: helpers

    private func statusName(_ s: SnapshotStatus) -> String {
        switch s {
        case .active: return "active"
        case .done: return "done"
        case .error: return "error"
        case .stopped: return "stopped"
        @unknown default: return "active"
        }
    }

    private func kindName(_ k: InspectionEventKind) -> String {
        switch k {
        case .actor: return "actor"
        case .event: return "event"
        case .snapshot: return "snapshot"
        default: return "event"
        }
    }
}
