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
        let rankGap = style.rankSpacing + labelSpan + 28
        // Vertical rhythm has to clear the labels on short same-column edges too, so it's generous.
        let nodeGap = max(style.nodeSpacing, style.edgeLabelFontSize * 3.4)

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

        // 3a. Column x-origins. Each inter-column gap is widened by how many edges route through it, so
        // busy gaps get room for all their channel tracks (the main "spread it out automatically" knob)
        // and quiet gaps stay tight.
        let colWidth: [CGFloat] = columns.map { col in col.map { size($0).width }.max() ?? 0 }
        let trackGap: CGFloat = max(16, style.edgeLabelFontSize * 1.5)
        var colOf: [String: Int] = [:]
        for (ci, col) in columns.enumerated() { for id in col { colOf[id] = ci } }
        func columnOf(_ nodeID: String) -> Int? {   // map any descendant up to its direct-child column
            var current: String? = nodeID
            while let c = current { if let ci = colOf[c] { return ci }; current = model.node(c)?.parentID }
            return nil
        }
        var crossings = [Int](repeating: 0, count: max(columns.count - 1, 0))
        for edge in model.edges where !edge.isSelfLoop {
            guard let ca = columnOf(edge.from), let cb = columnOf(edge.to) else { continue }
            if ca == cb { if ca < crossings.count { crossings[ca] += 1 } }   // same-column C uses the gap to the right
            else { for gap in min(ca, cb)..<max(ca, cb) { crossings[gap] += 1 } }
        }
        var colX: [CGFloat] = []
        var x: CGFloat = 0
        for ci in columns.indices {
            colX.append(x)
            x += colWidth[ci]
            if ci < columns.count - 1 { x += rankGap + CGFloat(crossings[ci]) * trackGap }
        }
        let contentWidth = x

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

        // 2. Distribute ports along each node side, ordered by the *other* endpoint's Y (so the fan
        //    doesn't cross at the port). Exit ports keyed by (from,side); entry ports by (to,side).
        func sideX(_ rect: CGRect, _ side: Side) -> CGFloat { side == .right ? rect.maxX : rect.minX }
        var exitPort = [CGPoint](repeating: .zero, count: edges.count)
        var entryPort = [CGPoint](repeating: .zero, count: edges.count)
        var exitGroups: [String: [Int]] = [:]
        var entryGroups: [String: [Int]] = [:]
        for i in edges.indices {
            exitGroups["\(edges[i].from)\u{1}\(cls[i].exitSide)", default: []].append(i)
            entryGroups["\(edges[i].to)\u{1}\(cls[i].entrySide)", default: []].append(i)
        }
        for (_, idxs) in exitGroups {
            let ordered = idxs.sorted {
                let ya = frames[edges[$0].to]!.midY, yb = frames[edges[$1].to]!.midY
                return ya != yb ? ya < yb : edges[$0].id < edges[$1].id
            }
            let rect = frames[edges[ordered[0]].from]!
            for (slot, i) in ordered.enumerated() {
                let frac = CGFloat(slot + 1) / CGFloat(ordered.count + 1)
                exitPort[i] = CGPoint(x: sideX(rect, cls[i].exitSide), y: rect.minY + rect.height * frac)
            }
        }
        for (_, idxs) in entryGroups {
            let ordered = idxs.sorted {
                let ya = frames[edges[$0].from]!.midY, yb = frames[edges[$1].from]!.midY
                return ya != yb ? ya < yb : edges[$0].id < edges[$1].id
            }
            let rect = frames[edges[ordered[0]].to]!
            for (slot, i) in ordered.enumerated() {
                let frac = CGFloat(slot + 1) / CGFloat(ordered.count + 1)
                entryPort[i] = CGPoint(x: sideX(rect, cls[i].entrySide), y: rect.minY + rect.height * frac)
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
