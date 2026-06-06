#if SWIFTXSTATE_GRAPH_UI
import CoreGraphics
import Foundation

/// The result of laying out a `GraphModel`: an absolute frame (in logical
/// coordinates) for every node, plus the overall content bounds. Containers
/// (compound / parallel) get frames that fully enclose their descendants, which
/// is what produces the nested "statechart" look.
public struct GraphLayoutResult: Sendable, Equatable {
    public var frames: [String: CGRect]
    /// The bounding rectangle of every frame, used to center/fit the graph.
    public var bounds: CGRect

    public static let empty = GraphLayoutResult(frames: [:], bounds: .zero)

    public func frame(_ id: String) -> CGRect? { frames[id] }
}

/// A deterministic, dependency-free layout engine for statecharts.
///
/// Each compound region is laid out as a left-to-right layered flow (ranks derived
/// from its internal transitions); each parallel region stacks its sub-regions
/// vertically. Containers are then sized to wrap their children with padding and a
/// header band for the region title. The whole thing is computed once and cached by
/// the view, so per-frame rendering is just a transform over precomputed rectangles.
public enum GraphLayout {
    public static func compute(
        model: GraphModel,
        style: GraphStyle,
        manualOffsets: [String: CGSize] = [:]
    ) -> GraphLayoutResult {
        guard !model.nodes.isEmpty, !model.rootID.isEmpty else { return .empty }

        var sizes: [String: CGSize] = [:]
        // A child's position relative to its parent's content area (inside padding+header).
        var childLocal: [String: CGPoint] = [:]
        // A parent's content-area origin relative to the parent's own frame origin.
        var contentInset: [String: CGPoint] = [:]

        // MARK: Measure pass (bottom-up)

        func measure(_ id: String) {
            guard let node = model.node(id) else { return }
            let kids = model.children(of: id)

            guard !kids.isEmpty else {
                sizes[id] = leafSize(label: node.label, style: style)
                return
            }
            for kid in kids { measure(kid) }

            // Custom placement: only when *every* direct child has an explicit position.
            if let override = style.nodeLayoutOverride,
               kids.allSatisfy({ override($0, model.node($0)?.relativePath ?? "") != nil }) {
                measureCustom(id: id, kids: kids, override: override)
            } else if node.type == .parallel {
                measureParallel(id: id, kids: kids)
            } else {
                measureCompound(id: id, kids: kids)
            }
        }

        /// Places children at consumer-supplied centers, then sizes the container to enclose them.
        func measureCustom(id: String, kids: [String], override: @Sendable (String, String) -> CGPoint?) {
            var centers: [String: CGPoint] = [:]
            for kid in kids {
                centers[kid] = override(kid, model.node(kid)?.relativePath ?? "") ?? .zero
            }
            var bounds = CGRect.null
            for kid in kids {
                let size = sizes[kid] ?? .zero
                let center = centers[kid] ?? .zero
                bounds = bounds.union(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                             width: size.width, height: size.height))
            }
            if bounds.isNull { bounds = .zero }
            for kid in kids {
                let size = sizes[kid] ?? .zero
                let center = centers[kid] ?? .zero
                childLocal[kid] = CGPoint(x: center.x - size.width / 2 - bounds.minX,
                                          y: center.y - size.height / 2 - bounds.minY)
            }
            finalizeContainer(id: id, contentSize: bounds.size, style: style)
        }

        func measureCompound(id: String, kids: [String]) {
            // Rank children left-to-right by their internal transition flow.
            let ranks = rankChildren(parentID: id, kids: kids, model: model)
            let maxRank = ranks.values.max() ?? 0
            var columns: [[String]] = Array(repeating: [], count: maxRank + 1)
            for kid in kids.sorted(by: {
                let ra = ranks[$0] ?? 0, rb = ranks[$1] ?? 0
                if ra != rb { return ra < rb }
                return (model.node($0)?.order ?? 0) < (model.node($1)?.order ?? 0)
            }) {
                columns[ranks[kid] ?? 0].append(kid)
            }

            let nodeSpacing = style.nodeSpacing
            var colWidth: [CGFloat] = []
            var colHeight: [CGFloat] = []
            for col in columns {
                colWidth.append(col.map { sizes[$0]?.width ?? 0 }.max() ?? 0)
                let h = col.reduce(0) { $0 + (sizes[$1]?.height ?? 0) }
                    + CGFloat(max(col.count - 1, 0)) * nodeSpacing
                colHeight.append(h)
            }
            let contentHeight = colHeight.max() ?? 0

            var x: CGFloat = 0
            for (ci, col) in columns.enumerated() {
                let w = colWidth[ci]
                var y = (contentHeight - colHeight[ci]) / 2
                for kid in col {
                    let s = sizes[kid] ?? .zero
                    childLocal[kid] = CGPoint(x: x + (w - s.width) / 2, y: y)
                    y += s.height + nodeSpacing
                }
                x += w
                if ci < columns.count - 1 { x += style.rankSpacing }
            }
            finalizeContainer(id: id, contentSize: CGSize(width: x, height: contentHeight), style: style)
        }

        func measureParallel(id: String, kids: [String]) {
            // Stack regions vertically; equalize their widths so the divider reads cleanly.
            let width = kids.map { sizes[$0]?.width ?? 0 }.max() ?? 0
            let gap = style.regionSpacing
            var y: CGFloat = 0
            for kid in kids {
                childLocal[kid] = CGPoint(x: 0, y: y)
                y += (sizes[kid]?.height ?? 0) + gap
            }
            let contentHeight = kids.isEmpty ? 0 : y - gap
            finalizeContainer(id: id, contentSize: CGSize(width: width, height: contentHeight), style: style)
        }

        func finalizeContainer(id: String, contentSize: CGSize, style: GraphStyle) {
            let pad = style.regionPadding
            let header = style.regionHeaderHeight
            sizes[id] = CGSize(
                width: contentSize.width + pad * 2,
                height: contentSize.height + header + pad
            )
            contentInset[id] = CGPoint(x: pad, y: header)
        }

        // MARK: Assign pass (top-down, applying manual drag offsets cumulatively)

        var frames: [String: CGRect] = [:]
        func assign(_ id: String, origin: CGPoint) {
            let off = manualOffsets[id] ?? .zero
            let o = CGPoint(x: origin.x + off.width, y: origin.y + off.height)
            let size = sizes[id] ?? .zero
            frames[id] = CGRect(origin: o, size: size)

            let inset = contentInset[id] ?? .zero
            let contentOrigin = CGPoint(x: o.x + inset.x, y: o.y + inset.y)
            for kid in model.children(of: id) {
                let local = childLocal[kid] ?? .zero
                assign(kid, origin: CGPoint(x: contentOrigin.x + local.x, y: contentOrigin.y + local.y))
            }
        }

        measure(model.rootID)
        assign(model.rootID, origin: .zero)

        // MARK: Bounds

        var bounds = CGRect.null
        for frame in frames.values { bounds = bounds.union(frame) }
        if bounds.isNull { bounds = .zero }

        return GraphLayoutResult(frames: frames, bounds: bounds)
    }

    // MARK: - Helpers

    private static func leafSize(label: String, style: GraphStyle) -> CGSize {
        let estimated = estimatedTextWidth(label, fontSize: style.nodeLabelFontSize)
        let width = max(style.nodeMinWidth, estimated + style.nodePadding * 2)
        return CGSize(width: width, height: style.nodeMinHeight)
    }

    /// Cheap monospace-ish width estimate (layout runs outside any graphics context).
    static func estimatedTextWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        CGFloat(text.count) * fontSize * 0.62
    }

    /// Layers a compound region's direct children left-to-right by their distance from
    /// the initial state, following internal transitions in a deterministic BFS. Back
    /// edges (cycles) are ignored because their target is already ranked, which keeps the
    /// flow flowing forward — and makes structurally-identical regions lay out identically.
    private static func rankChildren(parentID: String, kids: [String], model: GraphModel) -> [String: Int] {
        let childSet = Set(kids)
        let order = Dictionary(uniqueKeysWithValues: kids.map { ($0, model.node($0)?.order ?? 0) })

        // Map any node to the direct child of `parentID` that contains it.
        func directChild(of nodeID: String) -> String? {
            var current: String? = nodeID
            while let c = current {
                if model.node(c)?.parentID == parentID { return c }
                current = model.node(c)?.parentID
            }
            return nil
        }

        var adjacency: [String: [String]] = [:]
        for edge in model.edges {
            guard let a = directChild(of: edge.from),
                  let b = directChild(of: edge.to),
                  a != b, childSet.contains(a), childSet.contains(b) else { continue }
            adjacency[a, default: []].append(b)
        }
        // Deterministic neighbour order.
        for key in adjacency.keys {
            adjacency[key]?.sort { (order[$0] ?? 0) < (order[$1] ?? 0) }
        }

        // Seed roots: the initial child first, then any child with no incoming edge,
        // then (for fully cyclic regions) the lowest-order child — all in definition order.
        let hasIncoming = Set(adjacency.values.flatMap { $0 })
        let initialID = kids.first { model.node($0)?.isInitialChild == true }
        var roots: [String] = []
        if let initialID { roots.append(initialID) }
        roots.append(contentsOf: kids.filter { !hasIncoming.contains($0) && $0 != initialID }
            .sorted { (order[$0] ?? 0) < (order[$1] ?? 0) })
        if roots.isEmpty, let fallback = kids.min(by: { (order[$0] ?? 0) < (order[$1] ?? 0) }) {
            roots = [fallback]
        }

        var rank: [String: Int] = [:]
        var queue: [String] = []
        for root in roots where rank[root] == nil {
            rank[root] = 0
            queue.append(root)
        }
        var head = 0
        while head < queue.count {
            let node = queue[head]; head += 1
            let next = (rank[node] ?? 0) + 1
            for neighbour in adjacency[node] ?? [] where rank[neighbour] == nil {
                rank[neighbour] = next
                queue.append(neighbour)
            }
        }
        // Any node not reached from a root (shouldn't happen, but be safe).
        for kid in kids where rank[kid] == nil { rank[kid] = 0 }
        return rank
    }
}
#endif
