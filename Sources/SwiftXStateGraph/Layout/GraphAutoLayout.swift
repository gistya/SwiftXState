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

        // Give the flow room for the edge labels that ride between columns: widen each rank gap by the
        // widest label crossing this region, and open up the vertical rhythm so stacked labels don't
        // collide. Without this the auto-layout packs nodes tight and reads as cramped on first load.
        let labelSpan = maxEdgeLabelWidth(parentID: parentID, kids: kids, model: model, style: style)
        // Spread the whole region out more the busier it is: a region with many transitions per state
        // needs 2×+ the breathing room of a sparse one. Scales the base gaps by average out-degree.
        let childSet0 = Set(kids)
        func directKid(_ id: String) -> String? {
            var c: String? = id
            while let x = c { if childSet0.contains(x) { return x }; c = model.node(x)?.parentID }
            return nil
        }
        let internalEdges = model.edges.filter {
            !$0.isSelfLoop
                && directKid($0.from) != nil && directKid($0.to) != nil
                && directKid($0.from) != directKid($0.to)
        }.count
        let density = kids.isEmpty ? 0 : CGFloat(internalEdges) / CGFloat(kids.count)
        let spread = max(1.0, min(2.2, density))          // ≥1×, up to ~2.2× when densely connected
        // Scale the base spacing by density, but keep the (fixed-size) label allowance additive so one
        // very wide label doesn't multiply into every gap and balloon the whole graph.
        let rankGap = style.rankSpacing * spread + labelSpan + 28
        let nodeGap = max(style.nodeSpacing, style.edgeLabelFontSize * 2.4) * spread

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
        
        struct Dat {
            var id: String
            var key: Double
            var tie: Int
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
                        .map { Dat(id: $0, key: barycenter($0), tie: currentPos[$0] ?? 0) }
                        .sorted { $0.key != $1.key ? $0.key < $1.key : $0.tie < $1.tie }
                        .map(\.id)
                }
            }
        }

        // 3a. Give every node its OWN column (a staggered grid, not stacked ranks). Column order stays
        // rank-major so the flow reads left-to-right, but no two nodes share an X. Combined with unique
        // rows below, a horizontal edge segment lives in a node's own row where nothing else sits and
        // vertical segments live in the single-node gaps — which keeps the orthogonal routing clean even
        // as the graph spreads out. Each gap still widens by how many edges cross it.
        let trackGap: CGFloat = max(16, style.edgeLabelFontSize * 1.5)
        let colOrder = columns.flatMap { $0 }                 // rank-major, barycenter within rank
        var colIndexOf: [String: Int] = [:]
        for (i, id) in colOrder.enumerated() { colIndexOf[id] = i }
        func colIndex(_ nodeID: String) -> Int? {             // map any descendant up to its column node
            var current: String? = nodeID
            while let c = current { if let i = colIndexOf[c] { return i }; current = model.node(c)?.parentID }
            return nil
        }
        var crossings = [Int](repeating: 0, count: max(colOrder.count - 1, 0))
        for edge in model.edges where !edge.isSelfLoop {
            guard let a = colIndex(edge.from), let b = colIndex(edge.to) else { continue }
            if a == b { if a < crossings.count { crossings[a] += 1 } }
            else { for gap in min(a, b)..<max(a, b) { crossings[gap] += 1 } }
        }
        var colX = [CGFloat](repeating: 0, count: colOrder.count)
        var xCursor: CGFloat = 0
        for i in colOrder.indices {
            colX[i] = xCursor
            xCursor += size(colOrder[i]).width
            if i < colOrder.count - 1 { xCursor += rankGap + CGFloat(crossings[i]) * trackGap }
        }

        // 3b. Initial vertical stack, then neighbour-aligned coordinate assignment.
        var top: [String: CGFloat] = [:]
        for col in columns {
            var y: CGFloat = 0
            for id in col { top[id] = y; y += size(id).height + nodeGap }
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
                        if c - h / 2 < prevBottom + nodeGap {
                            c = prevBottom + nodeGap + h / 2
                        }
                        top[id] = c - h / 2
                        prevBottom = c + h / 2
                    }
                }
            }
        }

        // 4. Give every node its OWN row too, ordered by the neighbour-aligned Y from 3b (so connected
        // nodes stay vertically near each other) — one node per row, so no two share a Y. Place each
        // node at its (column, row) cell.
        let rowOrder = kids.sorted {
            let ca = center($0), cb = center($1)
            if ca != cb { return ca < cb }
            return (colIndexOf[$0] ?? 0) < (colIndexOf[$1] ?? 0)
        }
        var rowY: [String: CGFloat] = [:]
        var yCursor: CGFloat = 0
        for id in rowOrder {
            rowY[id] = yCursor
            yCursor += size(id).height + nodeGap
        }
        var local: [String: CGPoint] = [:]
        var maxRight: CGFloat = 0, maxBottom: CGFloat = 0
        for id in kids {
            let cx = colX[colIndexOf[id] ?? 0]
            let cy = rowY[id] ?? 0
            local[id] = CGPoint(x: cx, y: cy)
            maxRight = max(maxRight, cx + size(id).width)
            maxBottom = max(maxBottom, cy + size(id).height)
        }
        return (local, CGSize(width: maxRight, height: maxBottom))
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

    /// The widest estimated edge-label among transitions internal to this container — the extra room
    /// each rank gap needs so labels riding between columns stay legible.
    static func maxEdgeLabelWidth(parentID: String, kids: [String], model: GraphModel, style: GraphStyle) -> CGFloat {
        let childSet = Set(kids)
        func directChild(of nodeID: String) -> String? {
            var current: String? = nodeID
            while let c = current {
                if model.node(c)?.parentID == parentID { return c }
                current = model.node(c)?.parentID
            }
            return nil
        }
        var maxWidth: CGFloat = 0
        for edge in model.edges where !edge.label.isEmpty {
            guard let a = directChild(of: edge.from), let b = directChild(of: edge.to),
                  a != b, childSet.contains(a), childSet.contains(b) else { continue }
            maxWidth = max(maxWidth, GraphLayout.estimatedTextWidth(edge.label, fontSize: style.edgeLabelFontSize))
        }
        return maxWidth
    }

    // MARK: - Edge routing (orthogonal / Manhattan)

    private enum Side { case left, right }

    /// Routes every (non-self-loop) edge as a **right-angle** polyline: it leaves a node side at a
    /// distinct port, runs vertically through a channel track in the gap between columns, then enters
    /// the target side. Ports are ordered by the far endpoint's Y (fewer crossings at the node), and
    /// parallel transitions take distinct tracks. Labels ride **flat** on the vertical channel segment
    /// (open space); a final pass de-overlaps them. A manual drag slides an edge's channel + label.
    static func routeEdges(
        model: GraphModel, frames: [String: CGRect], style: GraphStyle,
        edgeOffsets: [String: CGSize] = [:]
    ) -> [String: EdgeRoute] {
        let edges = model.edges
            .filter { !$0.isSelfLoop && frames[$0.from] != nil && frames[$0.to] != nil }
            .sorted { ($0.from, $0.to, $0.label) < ($1.from, $1.to, $1.label) }
        guard !edges.isEmpty else { return [:] }

        // 1. Exit/entry sides. Forward (target to the right) exits right / enters left; a back edge
        //    mirrors it; a near-same-column pair routes as a "C" out to the right.
        struct Cls { let exitSide: Side; let entrySide: Side; let sameColumn: Bool }
        let cls: [Cls] = edges.map { e in
            let s = frames[e.from]!, t = frames[e.to]!
            if abs(t.midX - s.midX) < (s.width + t.width) * 0.35 {
                return Cls(exitSide: .right, entrySide: .right, sameColumn: true)
            }
            return t.midX >= s.midX
                ? Cls(exitSide: .right, entrySide: .left, sameColumn: false)
                : Cls(exitSide: .left, entrySide: .right, sameColumn: false)
        }

        // 2. Distribute ports along each node side. Exits AND entries on the same side share one slot
        //    sequence, so an anti-parallel pair (A→B forward + B→A back) never lands on the same port
        //    pixel — each transition gets its own attachment point (else the two lines fuse at the node
        //    edge and read as one). Ordered by the *other* endpoint's Y so the fan doesn't cross.
        func sideX(_ rect: CGRect, _ side: Side) -> CGFloat { side == .right ? rect.maxX : rect.minX }
        var exitPort = [CGPoint](repeating: .zero, count: edges.count)
        var entryPort = [CGPoint](repeating: .zero, count: edges.count)
        // Members of a node-side: the edge index plus whether it attaches here as an exit or an entry.
        var sideMembers: [String: [(i: Int, isExit: Bool)]] = [:]
        for i in edges.indices {
            sideMembers["\(edges[i].from)\u{1}\(cls[i].exitSide)", default: []].append((i, true))
            sideMembers["\(edges[i].to)\u{1}\(cls[i].entrySide)", default: []].append((i, false))
        }
        func otherEndY(_ m: (i: Int, isExit: Bool)) -> CGFloat {
            m.isExit ? frames[edges[m.i].to]!.midY : frames[edges[m.i].from]!.midY
        }
        for (_, members) in sideMembers {
            let ordered = members.sorted {
                let ya = otherEndY($0), yb = otherEndY($1)
                if ya != yb { return ya < yb }
                if $0.isExit != $1.isExit { return $0.isExit }   // stable: exits before entries on a tie
                return edges[$0.i].id < edges[$1.i].id
            }
            // Every member shares this node & side (the group key), so one rect/side serves all.
            let first = ordered[0]
            let rect = first.isExit ? frames[edges[first.i].from]! : frames[edges[first.i].to]!
            let side = first.isExit ? cls[first.i].exitSide : cls[first.i].entrySide
            for (slot, m) in ordered.enumerated() {
                let frac = CGFloat(slot + 1) / CGFloat(ordered.count + 1)
                let pt = CGPoint(x: sideX(rect, side), y: rect.minY + rect.height * frac)
                if m.isExit { exitPort[m.i] = pt } else { entryPort[m.i] = pt }
            }
        }

        // 3. Lane index within each unordered pair, so parallel transitions take distinct tracks.
        var laneIndex = [Int](repeating: 0, count: edges.count)
        var laneCount = [Int](repeating: 1, count: edges.count)
        var pairMembers: [String: [Int]] = [:]
        for i in edges.indices {
            let key = edges[i].from < edges[i].to
                ? "\(edges[i].from)\u{1}\(edges[i].to)" : "\(edges[i].to)\u{1}\(edges[i].from)"
            pairMembers[key, default: []].append(i)
        }
        for (_, idxs) in pairMembers {
            let ordered = idxs.sorted { edges[$0].id < edges[$1].id }
            for (slot, i) in ordered.enumerated() { laneIndex[i] = slot; laneCount[i] = ordered.count }
        }

        let trackGap: CGFloat = max(16, style.edgeLabelFontSize * 1.5)

        // 4. Assign a distinct vertical track to every edge crossing a given column gap, spread across
        //    that gap's open interval and ordered by Y so tracks don't cross. Columns are recovered from
        //    the leaf frames (nodes in a column share midX); edges that don't map cleanly (nested /
        //    multi-column) fall back to a mid-gap lane. This is what actually de-crowds the channels.
        var colMinX: [CGFloat: CGFloat] = [:], colMaxX: [CGFloat: CGFloat] = [:]
        for (id, f) in frames where model.node(id)?.type.isContainer == false {
            let c = (f.midX * 100).rounded()
            colMinX[c] = min(colMinX[c] ?? .greatestFiniteMagnitude, f.minX)
            colMaxX[c] = max(colMaxX[c] ?? -.greatestFiniteMagnitude, f.maxX)
        }
        let colCenters = colMinX.keys.sorted()
        func colIdx(_ nodeID: String) -> Int? {
            guard let f = frames[nodeID] else { return nil }
            return colCenters.firstIndex(of: (f.midX * 100).rounded())
        }
        var channelXOverride: [Int: CGFloat] = [:]
        var gapBuckets: [Int: [Int]] = [:]
        for i in edges.indices where !cls[i].sameColumn {
            guard let ca = colIdx(edges[i].from), let cb = colIdx(edges[i].to), ca != cb else { continue }
            gapBuckets[min(ca, cb), default: []].append(i)
        }
        for (g, idxs) in gapBuckets {
            guard g + 1 < colCenters.count,
                  let left = colMaxX[colCenters[g]], let right = colMinX[colCenters[g + 1]], right > left else { continue }
            let ordered = idxs.sorted {
                let ma = (exitPort[$0].y + entryPort[$0].y) / 2, mb = (exitPort[$1].y + entryPort[$1].y) / 2
                return ma != mb ? ma < mb : edges[$0].id < edges[$1].id
            }
            for (slot, i) in ordered.enumerated() {
                channelXOverride[i] = left + (right - left) * CGFloat(slot + 1) / CGFloat(ordered.count + 1)
            }
        }

        var routes: [String: EdgeRoute] = [:]

        for i in edges.indices {
            let edge = edges[i]
            let to = frames[edge.to]!
            let exit = exitPort[i], entry = entryPort[i]
            let laneOff = (CGFloat(laneIndex[i]) - CGFloat(laneCount[i] - 1) / 2) * trackGap

            // Channel x for the vertical run: the assigned per-gap track for a normal edge; just outside
            // the node for a same-column "C"; a mid-gap lane as the fallback.
            var channelX: CGFloat
            if cls[i].sameColumn {
                channelX = max(exit.x, to.maxX) + 34 + CGFloat(laneIndex[i]) * trackGap
            } else {
                channelX = channelXOverride[i] ?? ((exit.x + entry.x) / 2 + laneOff)
            }

            // Manual drag: slide the vertical channel horizontally, the label along it vertically.
            let drag = edgeOffsets[edge.id] ?? .zero
            channelX += drag.width

            // Two right-angle bends: exit → channel → entry.
            let points = [
                exit,
                CGPoint(x: channelX, y: exit.y),
                CGPoint(x: channelX, y: entry.y),
                entry,
            ]

            // Flat label on the vertical channel segment, slid by any vertical drag but kept on the run.
            let yLo = min(exit.y, entry.y), yHi = max(exit.y, entry.y)
            let labelY = min(max((exit.y + entry.y) / 2 + drag.height, yLo), yHi)

            routes[edge.id] = EdgeRoute(
                edgeID: edge.id,
                points: points,
                labelAnchor: CGPoint(x: channelX, y: labelY),
                labelAngle: 0,               // flat; the declutter separates labels by moving, not tilting
                laneIndex: laneIndex[i],
                laneCount: laneCount[i],
                labelWidth: edge.label.isEmpty ? 0 : GraphLayout.estimatedTextWidth(edge.label, fontSize: style.edgeLabelFontSize)
            )
        }

        declutterLabels(&routes, style: style)
        return routes
    }

    /// Nudges overlapping label pills apart (axis of least penetration, a few iterations) so labels
    /// never sit on top of one another — edges may still cross, but their labels stay readable.
    private static func declutterLabels(_ routes: inout [String: EdgeRoute], style: GraphStyle) {
        struct Pill { let id: String; var center: CGPoint; let halfW: CGFloat; let halfH: CGFloat }
        let halfH = style.edgeLabelFontSize * 0.7 + 3
        var pills: [Pill] = routes.keys.sorted().compactMap { id in
            let route = routes[id]!
            guard route.labelWidth > 0 else { return nil }
            return Pill(id: id, center: route.labelAnchor, halfW: route.labelWidth / 2 + 4, halfH: halfH)
        }
        guard pills.count > 1 else { return }

        for _ in 0..<16 {
            var moved = false
            for i in 0..<pills.count {
                for j in (i + 1)..<pills.count {
                    let dx = pills[j].center.x - pills[i].center.x
                    let dy = pills[j].center.y - pills[i].center.y
                    let overlapX = pills[i].halfW + pills[j].halfW - abs(dx)
                    let overlapY = pills[i].halfH + pills[j].halfH - abs(dy)
                    guard overlapX > 0, overlapY > 0 else { continue }
                    moved = true
                    if overlapX < overlapY {          // separate horizontally (least penetration)
                        let push = overlapX / 2 * (dx < 0 ? -1 : 1)
                        pills[i].center.x -= push; pills[j].center.x += push
                    } else {                          // separate vertically
                        let push = overlapY / 2 * (dy < 0 ? -1 : 1)
                        pills[i].center.y -= push; pills[j].center.y += push
                    }
                }
            }
            if !moved { break }
        }
        for pill in pills { routes[pill.id]?.labelAnchor = pill.center }
    }
}
#endif
