#if SWIFTXSTATE_GRAPH_UI
import SwiftUI

/// The shared graph surface: 2D canvas / 3D scene, toolbar, gestures, and macOS
/// scroll-wheel zoom. Driven by a `GraphRenderModel`; both public views embed this.
@MainActor
struct GraphRenderView: View {
    let render: GraphRenderModel
    @Environment(\.graphStyle) private var style

    @State private var panStart: CGSize?
    @State private var dragNodeID: String?
    @State private var dragBaseline: CGSize?
    @State private var dragEdgeID: String?
    @State private var dragEdgeBaseline: CGSize?
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
            onSelect: { render.selectedID = $0 },
            spacing: render.spacing3D
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
                if panStart == nil && dragNodeID == nil && dragEdgeID == nil {
                    let logical = render.transform.logical(from: value.startLocation)
                    if let id = render.layout.hitTest(logical, model: render.model),
                       render.model.node(id)?.type.isContainer == false {
                        // A leaf node: drag it (regions grow to follow).
                        dragNodeID = id
                        dragBaseline = render.manualOffsets[id] ?? .zero
                        render.selectedID = id
                    } else if let eid = render.layout.hitTestEdge(logical, threshold: 22 / render.zoom) {
                        // An edge / label: drag it into open space.
                        dragEdgeID = eid
                        dragEdgeBaseline = render.edgeOffsets[eid] ?? .zero
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
                } else if let eid = dragEdgeID, let baseline = dragEdgeBaseline {
                    render.edgeOffsets[eid] = CGSize(
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
            .onEnded { _ in
                // Persist the arrangement once a node/edge drag settles (not on a plain pan).
                if dragNodeID != nil || dragEdgeID != nil { render.persistArrangement() }
                panStart = nil; dragNodeID = nil; dragBaseline = nil; dragEdgeID = nil; dragEdgeBaseline = nil
            }
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

                #if canImport(SceneKit) && !os(watchOS)
                if render.renderMode == .threeD {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.secondary)
                        .help("Node spacing")
                    Slider(value: Binding(get: { render.spacing3D }, set: { render.spacing3D = $0 }), in: 1...4)
                        .frame(width: 130)
                        .help("Spread the nodes apart; regions grow to keep them enclosed")
                    Text(String(format: "×%.1f", render.spacing3D))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                }
                #endif

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
#endif
