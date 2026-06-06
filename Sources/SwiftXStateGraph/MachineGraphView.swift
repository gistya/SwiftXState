#if SWIFTXSTATE_GRAPH_UI
import SwiftUI
import SwiftXState

#if canImport(AppKit)
import AppKit
#endif

/// Which renderer the graph view is currently using.
public enum GraphRenderMode: String, Sendable, CaseIterable {
    case twoD = "2D"
    case threeD = "3D"
}

// MARK: - Render model (non-generic interaction + view state)

/// Holds all mutable render/interaction state for a graph. A reference type so the
/// macOS scroll-wheel monitor can drive zoom directly and live updates can be pushed in
/// without struct-mutation gymnastics. Deliberately **non-generic**: both the live
/// `MachineGraphView<Context>` and the type-erased `StateGraphView` drive the same core.
@MainActor
@Observable
final class GraphRenderModel {
    var model: GraphModel
    var layout: GraphLayoutResult = .empty
    var activeIDs: Set<String> = []

    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var viewport: CGSize = .zero
    /// The canvas's frame in the window's global coordinate space — so mouse-wheel zoom
    /// only fires when the cursor is actually over the graph (not, say, an adjacent sidebar).
    var canvasFrame: CGRect = .zero
    var manualOffsets: [String: CGSize] = [:]
    var selectedID: String?
    var renderMode: GraphRenderMode = .twoD
    /// Logical point anchored to the viewport center. Frozen during interaction so dragging
    /// a node doesn't drift the graph; refreshed on fit/reset.
    var viewCenter: CGPoint = .zero

    @ObservationIgnored var style: GraphStyle = .default

    init(model: GraphModel) {
        self.model = model
    }

    // MARK: Model + active state

    /// Swaps in a new structure (e.g. the inspector selecting a different actor).
    func setModel(_ newModel: GraphModel) {
        guard newModel.structureHash != model.structureHash else {
            model = newModel
            return
        }
        model = newModel
        manualOffsets.removeAll()
        selectedID = nil
        viewCenter = .zero
    }

    /// Recomputes the active node set from a live `StateValue` (drives highlighting).
    func setActive(stateValue: StateValue?) {
        guard let stateValue else { activeIDs = []; return }
        var ids = Set<String>()
        for node in model.nodes where !node.relativePath.isEmpty {
            if stateValue.matches(node.relativePath) { ids.insert(node.id) }
        }
        activeIDs = ids
    }

    // MARK: Layout

    func recomputeLayout() {
        layout = GraphLayout.compute(model: model, style: style, manualOffsets: manualOffsets)
        if viewCenter == .zero { viewCenter = CGPoint(x: layout.bounds.midX, y: layout.bounds.midY) }
    }

    func recenter() {
        viewCenter = CGPoint(x: layout.bounds.midX, y: layout.bounds.midY)
    }

    // MARK: View fitting

    var transform: GraphTransform {
        GraphTransform(zoom: zoom, pan: pan, viewport: viewport, center: viewCenter)
    }

    func fit(animated: Bool = true) {
        let bounds = layout.bounds
        guard viewport.width > 0, viewport.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        recenter()
        let available = CGSize(
            width: viewport.width * (1 - style.fitPadding * 2),
            height: viewport.height * (1 - style.fitPadding * 2)
        )
        let target = min(available.width / bounds.width, available.height / bounds.height)
        let clamped = max(style.zoomMin, min(style.zoomMax, target))
        if animated {
            withAnimation(.easeInOut(duration: style.layoutAnimationDuration)) { zoom = clamped; pan = .zero }
        } else {
            zoom = clamped; pan = .zero
        }
    }

    func resetView() {
        manualOffsets.removeAll()
        selectedID = nil
        recomputeLayout()
        recenter()
        fit()
    }

    // MARK: Zoom around an anchor (screen coordinates)

    func zoom(to newZoomRaw: CGFloat, anchor: CGPoint) {
        let newZoom = max(style.zoomMin, min(style.zoomMax, newZoomRaw))
        let anchorLogical = transform.logical(from: anchor)
        pan = CGSize(
            width: anchor.x - viewport.width / 2 - (anchorLogical.x - viewCenter.x) * newZoom,
            height: anchor.y - viewport.height / 2 - (anchorLogical.y - viewCenter.y) * newZoom
        )
        zoom = newZoom
    }

    func zoomBy(factor: CGFloat, anchor: CGPoint? = nil) {
        let a = anchor ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        zoom(to: zoom * factor, anchor: a)
    }
}

// MARK: - Render view (shared chrome, gestures, renderers)

/// The shared graph surface: 2D canvas / 3D scene, toolbar, gestures, and macOS
/// scroll-wheel zoom. Driven by a `GraphRenderModel`; both public views embed this.
@MainActor
struct GraphRenderView: View {
    let render: GraphRenderModel
    @Environment(\.graphStyle) private var style

    @State private var panStart: CGSize?
    @State private var dragNodeID: String?
    @State private var dragBaseline: CGSize?
    @State private var zoomStart: CGFloat?
    
    #if canImport(AppKit)
    @State private var scrollBridge = ScrollWheelBridge()
    #endif
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                style.backgroundColor.ignoresSafeArea()

                Group {
                    if render.renderMode == .threeD {
                        graph3D
                    } else {
                        graph2D
                    }
                }

                toolbar
                emptyStateOverlay
            }
            .onAppear {
                render.style = style
                render.viewport = geo.size
                render.canvasFrame = geo.frame(in: .global)
                render.recomputeLayout()
                if render.layout.bounds.width > 0 { render.fit(animated: false) }
                installScrollWheel()
            }
            #if os(macOS)
            .onDisappear { scrollBridge.stop() }
            #endif
            .onChange(of: geo.size) { _, newSize in
                let wasZero = render.viewport == .zero
                render.viewport = newSize
                if wasZero { render.fit(animated: false) }
            }
            .onChange(of: geo.frame(in: .global)) { _, frame in
                render.canvasFrame = frame
            }
            // The model swapped (e.g. a different actor selected): relayout + refit.
            .onChange(of: render.model.structureHash) { _, _ in
                render.style = style
                render.recomputeLayout()
                render.recenter()
                render.fit(animated: false)
            }
        }
    }

    @ViewBuilder
    private var graph2D: some View {
        GraphCanvas(
            model: render.model,
            layout: render.layout,
            activeIDs: render.activeIDs,
            selectedID: render.selectedID,
            style: style,
            zoom: render.zoom,
            pan: render.pan,
            center: render.viewCenter
        )
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(selectionGesture)
    }

    @ViewBuilder
    private var graph3D: some View {
        #if canImport(SceneKit) && !os(watchOS)
        GraphScene3DView(
            model: render.model,
            layout: render.layout,
            activeIDs: render.activeIDs,
            selectedID: render.selectedID,
            style: style,
            onSelect: { render.selectedID = $0 }
        )
        #else
        Text("3D rendering is not available on this platform.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if panStart == nil && dragNodeID == nil {
                    let logical = render.transform.logical(from: value.startLocation)
                    if let id = render.layout.hitTest(logical, model: render.model),
                       render.model.node(id)?.type.isContainer == false {
                        dragNodeID = id
                        dragBaseline = render.manualOffsets[id] ?? .zero
                        render.selectedID = id
                    } else {
                        panStart = render.pan
                    }
                }
                if let id = dragNodeID, let baseline = dragBaseline {
                    render.manualOffsets[id] = CGSize(
                        width: baseline.width + value.translation.width / render.zoom,
                        height: baseline.height + value.translation.height / render.zoom
                    )
                    render.recomputeLayout()
                } else if let start = panStart {
                    render.pan = CGSize(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    )
                }
            }
            .onEnded { _ in panStart = nil; dragNodeID = nil; dragBaseline = nil }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = render.zoom }
                let base = zoomStart ?? render.zoom
                render.zoom(to: base * value.magnification, anchor: value.startLocation)
            }
            .onEnded { _ in zoomStart = nil }
    }

    private var selectionGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let logical = render.transform.logical(from: value.location)
                let hit = render.layout.hitTest(logical, model: render.model)
                render.selectedID = (hit == render.selectedID) ? nil : hit
            }
    }

    private func installScrollWheel() {
        #if canImport(AppKit)
        scrollBridge.start { [weak render] deltaX, deltaY, precise, windowPoint in
            guard let render else { return false }
            // In 3D mode let SceneKit's camera controller handle scroll/two-finger pan & zoom.
            guard render.renderMode == .twoD else { return false }
            // Only handle scrolls over the graph canvas (window-global coords); let the
            // sidebar and other views scroll normally.
            guard render.canvasFrame.contains(windowPoint) else { return false }
            if precise {
                // Trackpad two-finger swipe → pan.
                render.pan = CGSize(width: render.pan.width + deltaX, height: render.pan.height + deltaY)
            } else {
                // Mouse wheel → zoom anchored at the cursor.
                let anchor = CGPoint(x: windowPoint.x - render.canvasFrame.minX,
                                     y: windowPoint.y - render.canvasFrame.minY)
                let factor = deltaY > 0 ? 1.06 : (1 / 1.06)
                render.zoomBy(factor: factor, anchor: anchor)
            }
            return true
        }
        #endif
    }

    // MARK: Chrome

    private var toolbar: some View {
        VStack {
            HStack(spacing: 10) {
                #if canImport(SceneKit) && !os(watchOS)
                Picker("", selection: Binding(get: { render.renderMode }, set: { render.renderMode = $0 })) {
                    ForEach(GraphRenderMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
                .labelsHidden()
                #endif

                if render.renderMode == .twoD {
                    Button { render.zoomBy(factor: style.zoomStep) } label: { Image(systemName: "plus.magnifyingglass") }
                    Button { render.zoomBy(factor: 1 / style.zoomStep) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button("Fit") { render.fit() }
                    Button("Reset") { render.resetView() }
                    Text(String(format: "%.0f%%", render.zoom * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                }

                Spacer()

                Text("\(render.model.nodes.count) states · \(render.model.edges.count) transitions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(10)

            Spacer()

            if render.renderMode == .twoD {
                HStack { Spacer(); legend; Spacer() }
                    .padding(.bottom, 10)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: style.activeNodeFill, label: "Active")
            legendItem(color: style.idleNodeFill, label: "Idle", border: style.idleNodeStroke)
            legendItem(color: style.finalNodeFill, label: "Final")
            if let selected = render.selectedID, let node = render.model.node(selected) {
                Divider().frame(height: 12)
                Text(node.relativePath.isEmpty ? node.label : node.relativePath)
                    .font(.caption.monospaced())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }

    private func legendItem(color: Color, label: String, border: Color? = nil) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(border ?? .clear, lineWidth: 1))
                .frame(width: 14, height: 11)
            Text(label).font(.caption2)
        }
    }

    @ViewBuilder
    private var emptyStateOverlay: some View {
        if render.model.nodes.count <= 1 {
            VStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.largeTitle)
                Text("This machine has no nested states to graph.")
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Public: live, typed graph

/// The root SwiftUI view for rendering a live state-machine graph from a typed actor.
///
/// ```swift
/// MachineGraphView(actor: myActor, machine: MyMachine.machine)
///     .graphStyle(.dark)
///     .frame(minWidth: 800, minHeight: 600)
/// ```
///
/// Constructed with an `actor`, it subscribes to live snapshots and highlights the active
/// configuration in real time. The snapshot-only initializer renders a static configuration.
@MainActor
public struct MachineGraphView<Context: Sendable>: View {
    @State private var render: GraphRenderModel
    @State private var subscription = SubscriptionBox()
    private let actor: Actor<Context>?

    /// Live graph driven by an actor.
    public init(actor: Actor<Context>, machine: StateMachine<Context>) {
        self.actor = actor
        let model = GraphModelBuilder.build(from: machine)
        let render = GraphRenderModel(model: model)
        render.setActive(stateValue: actor.snapshot.value)
        _render = State(initialValue: render)
    }

    /// Static / replay graph from a snapshot (no live subscription).
    public init(machine: StateMachine<Context>, snapshot: MachineSnapshot<Context>) {
        self.actor = nil
        let model = GraphModelBuilder.build(from: machine)
        let render = GraphRenderModel(model: model)
        render.setActive(stateValue: snapshot.value)
        _render = State(initialValue: render)
    }

    public var body: some View {
        GraphRenderView(render: render)
            .onAppear {
                guard let actor, subscription.handle == nil else { return }
                render.setActive(stateValue: actor.snapshot.value)
                subscription.handle = actor.subscribe { [weak render] snapshot in
                    Task { @MainActor in render?.setActive(stateValue: snapshot.value) }
                }
            }
            .onDisappear { subscription.cancel() }
    }
}

// MARK: - Public: type-erased graph (definition + live state)

/// Renders a statechart from a `GraphModel` (or an exported definition) plus an optional
/// live `StateValue` for highlighting — without requiring a typed `Actor`/`StateMachine`.
/// This is what the inspector uses to graph any actor from its `definitionJSON`.
@MainActor
public struct StateGraphView: View {
    private let model: GraphModel
    private let stateValue: StateValue?
    @State private var render: GraphRenderModel

    public init(model: GraphModel, stateValue: StateValue? = nil) {
        self.model = model
        self.stateValue = stateValue
        let render = GraphRenderModel(model: model)
        render.setActive(stateValue: stateValue)
        _render = State(initialValue: render)
    }

    /// Builds the model from an exported machine definition (see `StateMachine.definitionJSON()`).
    public init(definitionJSON: String, machineID: String, stateValue: StateValue? = nil) {
        self.init(model: GraphModelBuilder.build(fromDefinitionJSON: definitionJSON, machineID: machineID),
                  stateValue: stateValue)
    }

    public var body: some View {
        GraphRenderView(render: render)
            .onChange(of: model.structureHash) { _, _ in
                render.setModel(model)
                render.setActive(stateValue: stateValue)
            }
            .onChange(of: stateValue) { _, newValue in
                render.setActive(stateValue: newValue)
            }
    }
}

// MARK: - Subscription lifetime holder

@MainActor
final class SubscriptionBox {
    var handle: Subscription?
    func cancel() { handle?.cancel(); handle = nil }
}

// MARK: - macOS scroll-wheel bridge

#if canImport(AppKit)
/// Installs a local scroll-wheel monitor so mouse-wheel zoom works on macOS.
@MainActor
final class ScrollWheelBridge {
    private var monitor: Any?

    /// `handler` receives `(deltaX, deltaY, isPrecise, location)` — `isPrecise` is true for
    /// trackpad gestures (→ pan) and false for mouse wheels (→ zoom). Location is in the key
    /// window's content view (top-left origin). Returns `true` if it consumed the event.
    func start(_ handler: @escaping (CGFloat, CGFloat, Bool, CGPoint) -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let contentView = event.window?.contentView else { return event }
            let point = contentView.convert(event.locationInWindow, from: nil)
            let flipped = CGPoint(x: point.x, y: contentView.bounds.height - point.y)
            if (event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0),
               handler(event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas, flipped) {
                return nil
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif
#endif
