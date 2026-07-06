#if SWIFTXSTATE_GRAPH_UI
import SwiftUI
import SwiftXState

#if canImport(AppKit)
import AppKit
#endif

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
    /// Per-edge manual drag offsets (edge id → logical delta). Lets the user pull a crowded arrow /
    /// label into open space; applied on top of the automatic routing.
    var edgeOffsets: [String: CGSize] = [:]
    var selectedID: String?
    var renderMode: GraphRenderMode = .twoD
    /// 3D-only: multiplies the spacing between node positions (1 = compact default). Regions,
    /// edges and labels all re-derive from the scaled positions, so they follow automatically.
    var spacing3D: CGFloat = 1
    /// Logical point anchored to the viewport center. Frozen during interaction so dragging
    /// a node doesn't drift the graph; refreshed on fit/reset.
    var viewCenter: CGPoint = .zero

    @ObservationIgnored var style: GraphStyle = .default

    init(model: GraphModel) {
        self.model = model
        // Restore any hand-arrangement saved for this machine so reopening the inspector doesn't forget it.
        let saved = GraphArrangementStore.load(model.machineID)
        manualOffsets = saved.nodes
        edgeOffsets = saved.edges
    }

    // MARK: Model + active state

    /// Swaps in a new structure (e.g. the inspector selecting a different actor).
    func setModel(_ newModel: GraphModel) {
        guard newModel.structureHash != model.structureHash else {
            model = newModel
            return
        }
        model = newModel
        // Load the arrangement saved for the machine we just switched to (rather than dropping it).
        let saved = GraphArrangementStore.load(newModel.machineID)
        manualOffsets = saved.nodes
        edgeOffsets = saved.edges
        selectedID = nil
        viewCenter = .zero
    }

    /// Persist the current hand-arrangement so it survives the inspector being reopened.
    func persistArrangement() {
        GraphArrangementStore.save(model.machineID, nodes: manualOffsets, edges: edgeOffsets)
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
        layout = GraphLayout.compute(model: model, style: style, manualOffsets: manualOffsets, edgeOffsets: edgeOffsets)
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
        edgeOffsets.removeAll()
        GraphArrangementStore.clear(model.machineID)   // forget the saved hand-arrangement too
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
#endif
