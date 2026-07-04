#if SWIFTXSTATE_GRAPH_UI
import CoreGraphics
import Foundation

// MARK: - Layered (Sugiyama) auto-layout + edge routing

/// The auto-layout half of `GraphLayout`, split out for readability. A compound region is laid out as
/// a left-to-right layered flow:
///
///   1. **Rank** each direct child by its distance from the initial state (reuses `rankChildren`).
///   2. **Order** within each rank by iterated *barycenter* sweeps — the classic crossing-minimization
///      heuristic: a node drifts toward the average position of its neighbours in the adjacent rank.
///   3. **Coordinate-assign** the vertical positions by pulling each node toward the mean centre of its
///      neighbours (so edges run roughly straight), then resolving overlaps top-to-bottom with a
///      minimum gap — order-preserving, so it never undoes step 2.
///
/// Edges are then routed over the final frames with **ports** (parallel edges leave/enter at distinct
/// border points) and **lanes** (a perpendicular fan), and each carries a label anchor + upright
/// tangent angle so the renderer can draw the label *along the line*. True orthogonal channel routing
/// is a deliberate follow-up (see the graph module's roadmap); this is bowed-lane routing.
extension GraphLayout {

    /// Lays out a compound container's direct children and returns each child's top-left position
    /// (relative to the container's content origin) plus the content size to wrap.
    static func autoCompoundLayout(
        parentID: String,
        kids: [String],
        model: GraphModel,
        style: GraphStyle,
        sizes: [String: CGSize]
    ) -> (local: [String: CGPoint], content: CGSize) {
        func size(_ id: String) -> CGSize { sizes[id] ?? .zero }

        // 1. Rank into columns; seed order by (rank, definition order).
        let ranks = rankChildren(parentID: parentID, kids: kids, model: model)
        let maxRank = ranks.values.max() ?? 0
        var columns: [[String]] = Array(repeating: [], count: maxRank + 1)
        for kid in kids.sorted(by: {
            let ra = ranks[$0] ?? 0, rb = ranks[$1] ?? 0
            if ra != rb { return ra < rb }
            return (model.node($0)?.order ?? 0) < (model.node($1)?.order ?? 0)
        }) {
            columns[ranks[kid] ?? 0].append(kid)
        }

        // 2. Barycenter ordering (undirected adjacency among direct children).
        let adjacency = directChildAdjacency(parentID: parentID, kids: kids, model: model)
        if columns.count > 1 {
            for iteration in 0..<4 {
                let downward = iteration % 2 == 0
                let indices = downward ? Array(1..<columns.count) : Array((0..<(columns.count - 1)).reversed())
                for ci in indices {
                    let refIndex = downward ? ci - 1 : ci + 1
                    guard columns.indices.contains(refIndex) else { continue }
                    var refPos: [String: Int] = [:]
                    for (i, id) in columns[refIndex].enumerated() { refPos[id] = i }
                    var currentPos: [String: Int] = [:]
                    for (i, id) in columns[ci].enumerated() { currentPos[id] = i }
                    func barycenter(_ id: String) -> Double {
                        let ns = (adjacency[id] ?? []).compactMap { refPos[$0] }
                        guard !ns.isEmpty else { return Double(currentPos[id] ?? 0) }
                        return Double(ns.reduce(0, +)) / Double(ns.count)
                    }
                    columns[ci] = columns[ci]
                        .map { (id: $0, key: barycenter($0), tie: currentPos[$0] ?? 0) }
                        .sorted { $0.key != $1.key ? $0.key < $1.key : $0.tie < $1.tie }
                        .map(\.id)
                }
            }
        }

        // 3a. Column x-origins from cumulative widths + rank spacing.
        let colWidth: [CGFloat] = columns.map { col in col.map { size($0).width }.max() ?? 0 }
        var colX: [CGFloat] = []
        var x: CGFloat = 0
        for ci in columns.indices {
            colX.append(x)
            x += colWidth[ci] + (ci < columns.count - 1 ? style.rankSpacing : 0)
        }
        let contentWidth = x

        // 3b. Initial vertical stack, then neighbour-aligned coordinate assignment.
        var top: [String: CGFloat] = [:]
        for col in columns {
            var y: CGFloat = 0
            for id in col { top[id] = y; y += size(id).height + style.nodeSpacing }
        }
        func center(_ id: String) -> CGFloat { (top[id] ?? 0) + size(id).height / 2 }
        if columns.count > 1 {
            for iteration in 0..<4 {
                let downward = iteration % 2 == 0
                let indices = downward ? Array(columns.indices) : Array(columns.indices.reversed())
                for ci in indices {
                    // Desired centre = mean of neighbour centres; place in existing column order,
                    // pushing down to keep a minimum gap (preserves the barycenter ordering).
                    var prevBottom = -CGFloat.greatestFiniteMagnitude
                    for id in columns[ci] {
                        let neighbours = (adjacency[id] ?? []).map { center($0) }
                        let desired = neighbours.isEmpty
                            ? center(id)
                            : neighbours.reduce(0, +) / CGFloat(neighbours.count)
                        let h = size(id).height
                        var c = desired
                        if c - h / 2 < prevBottom + style.nodeSpacing {
                            c = prevBottom + style.nodeSpacing + h / 2
                        }
                        top[id] = c - h / 2
                        prevBottom = c + h / 2
                    }
                }
            }
        }

        // 4. Normalize to a (0,0) content origin; center each node within its column band.
        let allTops = columns.flatMap { $0 }.map { top[$0] ?? 0 }
        let minTop = allTops.min() ?? 0
        var local: [String: CGPoint] = [:]
        var maxBottom: CGFloat = 0
        for ci in columns.indices {
            for id in columns[ci] {
                let t = (top[id] ?? 0) - minTop
                local[id] = CGPoint(x: colX[ci] + (colWidth[ci] - size(id).width) / 2, y: t)
                maxBottom = max(maxBottom, t + size(id).height)
            }
        }
        return (local, CGSize(width: contentWidth, height: maxBottom))
    }

    /// Undirected adjacency among a container's *direct* children (any deeper endpoint maps up to the
    /// direct child that contains it), in deterministic definition order.
    static func directChildAdjacency(parentID: String, kids: [String], model: GraphModel) -> [String: [String]] {
        let childSet = Set(kids)
        func directChild(of nodeID: String) -> String? {
            var current: String? = nodeID
            while let c = current {
                if model.node(c)?.parentID == parentID { return c }
                current = model.node(c)?.parentID
            }
            return nil
        }
        var adjacency: [String: Set<String>] = [:]
        for edge in model.edges {
            guard let a = directChild(of: edge.from),
                  let b = directChild(of: edge.to),
                  a != b, childSet.contains(a), childSet.contains(b) else { continue }
            adjacency[a, default: []].insert(b)
            adjacency[b, default: []].insert(a)
        }
        return adjacency.mapValues { set in
            set.sorted { (model.node($0)?.order ?? 0) < (model.node($1)?.order ?? 0) }
        }
    }

    // MARK: - Edge routing

    /// Routes every (non-self-loop) edge over the final node frames. Edges sharing an unordered node
    /// pair are fanned into distinct **lanes** and leave/enter their nodes at distinct **ports**, and
    /// each gets a label anchor staggered along the curve with an upright tangent angle.
    static func routeEdges(model: GraphModel, frames: [String: CGRect], style: GraphStyle) -> [String: EdgeRoute] {
        // Group by unordered pair so both directions (A→B and B→A) share a lane budget.
        var groups: [String: [GraphEdge]] = [:]
        for edge in model.edges where !edge.isSelfLoop {
            guard frames[edge.from] != nil, frames[edge.to] != nil else { continue }
            let key = edge.from < edge.to ? "\(edge.from)\u{1}\(edge.to)" : "\(edge.to)\u{1}\(edge.from)"
            groups[key, default: []].append(edge)
        }

        let laneGap: CGFloat = max(15, style.nodeSpacing * 0.75)
        var routes: [String: EdgeRoute] = [:]

        for (_, unsorted) in groups {
            let edges = unsorted.sorted { ($0.from, $0.to, $0.label) < ($1.from, $1.to, $1.label) }
            let n = edges.count
            for (i, edge) in edges.enumerated() {
                guard let a = frames[edge.from], let b = frames[edge.to] else { continue }
                let ac = CGPoint(x: a.midX, y: a.midY)
                let bc = CGPoint(x: b.midX, y: b.midY)
                let dx = bc.x - ac.x, dy = bc.y - ac.y
                let len = max(hypot(dx, dy), 0.0001)
                let perp = CGVector(dx: -dy / len, dy: dx / len)

                // Lane offset, symmetric around the bundle centre.
                let laneOffset = (CGFloat(i) - CGFloat(n - 1) / 2) * laneGap
                // Aim each lane at a perpendicularly-shifted target so it exits/enters at a distinct
                // border port (stays on the node boundary, unlike shifting the port point directly).
                let startAim = CGPoint(x: bc.x + perp.dx * laneOffset * 2, y: bc.y + perp.dy * laneOffset * 2)
                let endAim = CGPoint(x: ac.x + perp.dx * laneOffset * 2, y: ac.y + perp.dy * laneOffset * 2)
                let start = borderIntersection(rect: a, toward: startAim)
                let end = borderIntersection(rect: b, toward: endAim)

                // A single edge gets a gentle base bow; parallels rely on the lane offset.
                let bow = n == 1 ? min(len * 0.12, 30) : laneOffset
                let control = CGPoint(x: (start.x + end.x) / 2 + perp.dx * bow,
                                      y: (start.y + end.y) / 2 + perp.dy * bow)

                // Stagger labels along the bundle so same-pair pills don't stack.
                let t: CGFloat = n > 1 ? 0.30 + 0.40 * CGFloat(i) / CGFloat(max(n - 1, 1)) : 0.5
                let anchor = quadPoint(start, control, end, t)
                let tangent = quadTangent(start, control, end, t)
                var angle = atan2(tangent.dy, tangent.dx)
                if cos(angle) < 0 { angle += .pi } // keep the text upright (never mirrored)

                routes[edge.id] = EdgeRoute(
                    edgeID: edge.id,
                    points: [start, control, end],
                    labelAnchor: anchor,
                    labelAngle: angle,
                    laneIndex: i,
                    laneCount: n
                )
            }
        }
        return routes
    }

    // MARK: - Geometry helpers

    /// Intersection of `rect`'s border with the ray from its centre toward `point`.
    private static func borderIntersection(rect: CGRect, toward point: CGPoint) -> CGPoint {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - c.x, dy = point.y - c.y
        if abs(dx) < 0.0001 && abs(dy) < 0.0001 { return c }
        let hw = rect.width / 2, hh = rect.height / 2
        let tx = abs(dx) > 0.0001 ? hw / abs(dx) : .greatestFiniteMagnitude
        let ty = abs(dy) > 0.0001 ? hh / abs(dy) : .greatestFiniteMagnitude
        let t = min(tx, ty)
        return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
    }

    private static func quadPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
            y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y
        )
    }

    private static func quadTangent(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ t: CGFloat) -> CGVector {
        let u = 1 - t
        return CGVector(
            dx: 2 * u * (p1.x - p0.x) + 2 * t * (p2.x - p1.x),
            dy: 2 * u * (p1.y - p0.y) + 2 * t * (p2.y - p1.y)
        )
    }
}
#endif
