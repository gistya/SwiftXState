#if SWIFTXSTATE_GRAPH_UI
import SwiftUI

/// The 2D Canvas renderer. SwiftUI's `Canvas` is GPU-backed (Core Animation / Metal),
/// and because the model and layout are precomputed and cached by the parent view,
/// each redraw is just a transform over precomputed rectangles — comfortably handling
/// many hundreds of nodes where a DOM renderer would stall.
struct GraphCanvas: View {
    let model: GraphModel
    let layout: GraphLayoutResult
    let activeIDs: Set<String>
    let selectedID: String?
    let style: GraphStyle
    let zoom: CGFloat
    let pan: CGSize
    /// The logical point anchored to the viewport center (matches the parent's transform).
    let center: CGPoint

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let transform = GraphTransform(zoom: zoom, pan: pan, viewport: size, center: center)
            drawGrid(in: &context, size: size, transform: transform)

            // Switch into logical space for the graph itself.
            context.translateBy(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
            context.scaleBy(x: zoom, y: zoom)
            context.translateBy(x: -transform.center.x, y: -transform.center.y)

            let declutter = model.nodes.count > style.labelDeclutterThreshold

            drawRegions(in: &context)
            drawEdges(in: &context, showLabels: !declutter)
            drawInitialIndicators(in: &context)
            drawLeafNodes(in: &context, withShadow: !declutter)
        }
    }

    // MARK: Grid (screen space, scales with zoom for a sense of depth)

    private func drawGrid(in context: inout GraphicsContext, size: CGSize, transform: GraphTransform) {
        guard style.gridStyle != .none else { return }
        let spacing = style.gridSpacing * zoom
        guard spacing >= 6 else { return }
        let origin = transform.screen(from: .zero)

        switch style.gridStyle {
        case .none:
            return
        case .square:
            var path = Path()
            func first(_ start: CGFloat) -> CGFloat {
                let r = start.truncatingRemainder(dividingBy: spacing); return r >= 0 ? r : r + spacing
            }
            var x = first(origin.x)
            while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
            var y = first(origin.y)
            while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
            context.stroke(path, with: .color(style.gridColor), lineWidth: 1)
        case .hexagonal:
            context.stroke(hexGridPath(size: size, origin: origin, spacing: spacing),
                           with: .color(style.gridColor), lineWidth: 1)
        }
    }

    /// A pointy-top hexagonal lattice anchored to the logical origin (pans/zooms with content).
    private func hexGridPath(size: CGSize, origin: CGPoint, spacing: CGFloat) -> Path {
        let r = spacing * 0.62                 // hex radius (visually similar density to square grid)
        let w = sqrt(3.0) * r                  // horizontal center spacing
        let h = 1.5 * r                        // vertical center spacing (row pitch)
        var path = Path()

        func hexagon(cx: CGFloat, cy: CGFloat) {
            for i in 0..<6 {
                let angle = CGFloat.pi / 180 * (60 * CGFloat(i) - 90) // pointy-top
                let p = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }

        let jStart = Int(floor((0 - origin.y) / h)) - 1
        let jEnd = Int(ceil((size.height - origin.y) / h)) + 1
        let iStart = Int(floor((0 - origin.x) / w)) - 1
        let iEnd = Int(ceil((size.width - origin.x) / w)) + 1
        guard (jEnd - jStart) * (iEnd - iStart) < 20_000 else { return path } // guard pathological zoom-out

        for j in jStart...jEnd {
            let rowOffset = (j & 1) == 0 ? 0 : w / 2
            let cy = origin.y + CGFloat(j) * h
            for i in iStart...iEnd {
                hexagon(cx: origin.x + CGFloat(i) * w + rowOffset, cy: cy)
            }
        }
        return path
    }

    // MARK: Regions (containers)

    private func drawRegions(in context: inout GraphicsContext) {
        // Outermost first so nested regions paint on top.
        let containers = model.nodes
            .filter { $0.type.isContainer }
            .sorted { area(of: $0.id) > area(of: $1.id) }

        for node in containers {
            guard let rect = layout.frame(node.id) else { continue }
            let isParallel = node.type == .parallel
            let fill = isParallel ? style.parallelRegionFill : style.compoundRegionFill
            let stroke = isParallel ? style.parallelRegionStroke : style.compoundRegionStroke
            let shape = Path(roundedRect: rect, cornerRadius: style.regionCornerRadius)

            context.fill(shape, with: .color(fill))
            context.stroke(shape, with: .color(stroke), lineWidth: style.regionBorderWidth)

            // Dashed dividers between stacked parallel sub-regions.
            if isParallel {
                let kids = model.children(of: node.id).compactMap { layout.frame($0) }.sorted { $0.minY < $1.minY }
                for i in 1..<max(kids.count, 1) where kids.count > 1 {
                    let y = (kids[i - 1].maxY + kids[i].minY) / 2
                    var line = Path()
                    line.move(to: CGPoint(x: rect.minX + style.regionPadding, y: y))
                    line.addLine(to: CGPoint(x: rect.maxX - style.regionPadding, y: y))
                    context.stroke(
                        line,
                        with: .color(style.parallelDividerColor),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
                }
            }

            // Region title in the header band.
            let active = activeIDs.contains(node.id)
            let badge = isParallel ? "⫴ " : ""
            let title = Text(badge + node.label)
                .font(.system(size: style.regionTitleFontSize, weight: style.regionTitleWeight))
                .foregroundStyle(active ? style.activeRegionTitleColor : style.regionTitleColor)
            context.draw(
                title,
                at: CGPoint(x: rect.minX + style.regionPadding, y: rect.minY + style.regionHeaderHeight / 2),
                anchor: .leading
            )
        }
    }

    private func area(of id: String) -> CGFloat {
        guard let f = layout.frame(id) else { return 0 }
        return f.width * f.height
    }

    // MARK: Edges

    private func drawEdges(in context: inout GraphicsContext, showLabels: Bool) {
        let ordered = model.edges.sorted { $0.id < $1.id }
        let autoLayout = model.useAutoLayoutForInspection
        // Fan out edges that share an endpoint pair so duplicates / back-edges don't overlap. Used only
        // for the legacy (opted-out) path; the auto-layout path carries its lane data on each route.
        var laneCount: [String: Int] = [:]
        for edge in ordered { laneCount[pairKey(edge), default: 0] += 1 }
        var laneSeen: [String: Int] = [:]
        // Fan multiple self-loops on the same node so none is hidden beneath another.
        var selfLoopCount: [String: Int] = [:]
        for edge in ordered where edge.isSelfLoop { selfLoopCount[edge.from, default: 0] += 1 }
        var selfLoopSeen: [String: Int] = [:]

        for edge in ordered {
            guard let fromRect = layout.frame(edge.from), let toRect = layout.frame(edge.to) else { continue }
            let emphasized = edge.from == selectedID || edge.to == selectedID
            // Per-event colour ties each line to its label when auto-layout is on; opted-out machines
            // (e.g. the chess board grid) keep the classic neutral edge colour.
            let color = emphasized ? style.activeEdgeColor : (autoLayout ? eventColor(for: edge) : style.edgeColor)
            let width = emphasized ? style.activeEdgeWidth : style.edgeWidth

            if edge.isSelfLoop {
                let dash = edge.isGuarded ? style.guardedEdgeDash : []
                // Put the loop on the node's right when the space directly above is occupied by a
                // stacked sibling (so its label doesn't tuck behind that node).
                let onRight = spaceAboveBlocked(fromRect, excluding: edge.from)
                let idx = selfLoopSeen[edge.from, default: 0]
                selfLoopSeen[edge.from] = idx + 1
                drawSelfLoop(in: &context, rect: fromRect, edge: edge, color: color, width: width, dash: dash,
                             showLabel: showLabels, tint: autoLayout ? color : nil, onRight: onRight,
                             loopIndex: idx, loopCount: selfLoopCount[edge.from, default: 1])
                continue
            }

            // Auto-layout: draw the pre-routed edge (distinct ports + lane fan + along-line label).
            if let route = layout.route(edge.id) {
                let dash = edge.isGuarded ? style.guardedEdgeDash : laneDash(index: route.laneIndex, count: route.laneCount)
                drawRoutedEdge(in: &context, route: route, color: color, width: width, dash: dash)
                if showLabels, !edge.label.isEmpty {
                    drawRoutedLabel(in: &context, text: edge.label, at: route.labelAnchor, angle: route.labelAngle, tint: color)
                }
                continue
            }

            // Legacy centre-to-centre curve (auto-layout opted out).
            let dash = edge.isGuarded ? style.guardedEdgeDash : []
            let key = pairKey(edge)
            let lane = laneSeen[key, default: 0]
            laneSeen[key] = lane + 1
            let lanes = laneCount[key, default: 1]

            let toCenter = CGPoint(x: toRect.midX, y: toRect.midY)
            let fromCenter = CGPoint(x: fromRect.midX, y: fromRect.midY)
            let start = borderIntersection(rect: fromRect, toward: toCenter)
            let end = borderIntersection(rect: toRect, toward: fromCenter)

            let dx = end.x - start.x, dy = end.y - start.y
            let len = max(hypot(dx, dy), 1)
            // Single-sided normal: because a back-edge's start→end is reversed, its bow
            // automatically lands on the opposite side of the forward edge.
            let normal = CGPoint(x: -dy / len, y: dx / len)
            // Lane offset fans duplicates out around the base bow.
            let laneOffset = (CGFloat(lane) - CGFloat(lanes - 1) / 2) * 26
            let bow = max(22, min(len * style.edgeCurveTension * 0.6, 90))
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let control = CGPoint(
                x: mid.x + normal.x * (bow + laneOffset),
                y: mid.y + normal.y * (bow + laneOffset)
            )

            // Pull the end back so the line meets the arrowhead base, not the tip.
            let tangent = CGPoint(x: end.x - control.x, y: end.y - control.y)
            let tlen = max(hypot(tangent.x, tangent.y), 1)
            let unit = CGPoint(x: tangent.x / tlen, y: tangent.y / tlen)
            let lineEnd = CGPoint(x: end.x - unit.x * style.arrowLength, y: end.y - unit.y * style.arrowLength)

            var path = Path()
            path.move(to: start)
            path.addQuadCurve(to: lineEnd, control: control)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))

            drawArrowhead(in: &context, tip: end, direction: unit, color: color)

            if showLabels, !edge.label.isEmpty {
                // Stagger labels of parallel edges along the curve so wide labels don't stack.
                let t: CGFloat = lanes > 1 ? 0.32 + 0.36 * CGFloat(lane) / CGFloat(lanes - 1) : 0.5
                let mt = 1 - t
                let onCurve = CGPoint(
                    x: mt * mt * start.x + 2 * mt * t * control.x + t * t * lineEnd.x,
                    y: mt * mt * start.y + 2 * mt * t * control.y + t * t * lineEnd.y
                )
                drawEdgeLabel(in: &context, text: edge.label, at: onCurve)
            }
        }
    }

    /// Unordered endpoint key so a transition and its reverse share a lane group.
    private func pairKey(_ edge: GraphEdge) -> String {
        edge.from < edge.to ? "\(edge.from)|\(edge.to)" : "\(edge.to)|\(edge.from)"
    }

    private func drawSelfLoop(
        in context: inout GraphicsContext, rect: CGRect, edge: GraphEdge,
        color: Color, width: CGFloat, dash: [CGFloat], showLabel: Bool, tint: Color? = nil, onRight: Bool = false,
        loopIndex: Int = 0, loopCount: Int = 1
    ) {
        let r = style.selfLoopRadius
        var path = Path()
        let arrowTip: CGPoint, arrowDir: CGPoint, labelPoint: CGPoint

        if onRight {
            // A loop bulging off the node's right edge, label to its right — clears a stacked sibling above.
            let fan = CGFloat(loopIndex) - CGFloat(loopCount - 1) / 2
            let anchor = CGPoint(x: rect.maxX, y: rect.midY + fan * r * 2.3)
            let top = CGPoint(x: anchor.x, y: anchor.y - r * 0.5)
            let bottom = CGPoint(x: anchor.x, y: anchor.y + r * 0.5)
            path.move(to: top)
            path.addCurve(
                to: bottom,
                control1: CGPoint(x: anchor.x + r * 1.6, y: anchor.y - r),
                control2: CGPoint(x: anchor.x + r * 1.6, y: anchor.y + r)
            )
            arrowTip = bottom
            arrowDir = CGPoint(x: -0.9, y: 0.3)
            labelPoint = CGPoint(x: anchor.x + r * 1.4 + estimatedLabelWidth(edge.label) / 2, y: anchor.y)
        } else {
            // Split the loops between the top and bottom edges (first ceil(n/2) on top, the rest on the
            // bottom) so a node with several self-transitions doesn't crowd them — and their labels — onto
            // one edge. Each edge fans its own group across X.
            let topCount = (loopCount + 1) / 2
            let onTop = loopIndex < topCount
            let localCount = onTop ? topCount : loopCount - topCount
            let localIndex = onTop ? loopIndex : loopIndex - topCount
            let fan = CGFloat(localIndex) - CGFloat(localCount - 1) / 2
            let anchor = CGPoint(x: rect.midX + fan * r * 2.4, y: onTop ? rect.minY : rect.maxY)
            let side: CGFloat = onTop ? -1 : 1     // bulge up (top) or down (bottom)
            let left = CGPoint(x: anchor.x - r * 0.5, y: anchor.y)
            let right = CGPoint(x: anchor.x + r * 0.5, y: anchor.y)
            path.move(to: left)
            path.addCurve(
                to: right,
                control1: CGPoint(x: anchor.x - r, y: anchor.y + side * r * 1.6),
                control2: CGPoint(x: anchor.x + r, y: anchor.y + side * r * 1.6)
            )
            arrowTip = right
            arrowDir = CGPoint(x: 0.2, y: -side)   // point back into the node
            labelPoint = CGPoint(x: anchor.x, y: anchor.y + side * r * 1.5)
        }

        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        drawArrowhead(in: &context, tip: arrowTip, direction: arrowDir, color: color)
        if showLabel, !edge.label.isEmpty {
            drawEdgeLabel(in: &context, text: edge.label, at: labelPoint, tint: tint)
        }
    }

    /// Cheap label-width estimate matching the layout engine's, for placing a side self-loop's label.
    private func estimatedLabelWidth(_ text: String) -> CGFloat {
        CGFloat(text.count) * style.edgeLabelFontSize * 0.62
    }

    /// Whether another (non-container) node sits directly above `rect` within self-loop reach — so a
    /// top self-loop would collide with it.
    private func spaceAboveBlocked(_ rect: CGRect, excluding id: String) -> Bool {
        let reach = style.selfLoopRadius * 2.6
        for (nodeID, frame) in layout.frames where nodeID != id {
            guard model.node(nodeID)?.type.isContainer == false else { continue }
            if frame.maxX > rect.minX, frame.minX < rect.maxX,
               frame.maxY <= rect.minY + 2, rect.minY - frame.maxY < reach {
                return true
            }
        }
        return false
    }

    private func drawArrowhead(in context: inout GraphicsContext, tip: CGPoint, direction: CGPoint, color: Color) {
        let len = style.arrowLength
        let halfWidth = style.arrowWidth / 2
        let base = CGPoint(x: tip.x - direction.x * len, y: tip.y - direction.y * len)
        let perp = CGPoint(x: -direction.y, y: direction.x)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x + perp.x * halfWidth, y: base.y + perp.y * halfWidth))
        path.addLine(to: CGPoint(x: base.x - perp.x * halfWidth, y: base.y - perp.y * halfWidth))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    private func drawEdgeLabel(in context: inout GraphicsContext, text: String, at point: CGPoint, tint: Color? = nil) {
        let resolved = context.resolve(
            Text(text)
                .font(.system(size: style.edgeLabelFontSize, weight: .medium))
                .foregroundStyle(style.edgeLabelColor)
        )
        let textSize = resolved.measure(in: CGSize(width: 400, height: 100))
        let pad: CGFloat = 4
        let bg = CGRect(
            x: point.x - textSize.width / 2 - pad,
            y: point.y - textSize.height / 2 - pad / 2,
            width: textSize.width + pad * 2,
            height: textSize.height + pad
        )
        let pill = Path(roundedRect: bg, cornerRadius: 4)
        context.fill(pill, with: .color(style.edgeLabelBackground))
        // A tinted outline in the edge colour ties the label to its line (the disambiguation cue).
        if let tint { context.stroke(pill, with: .color(tint), lineWidth: 1.5) }
        context.draw(resolved, at: point, anchor: .center)
    }

    // MARK: Auto-layout edge helpers

    /// The primary cue mapping a transition line to its label — a stable per-event colour (see
    /// `GraphEdge.stableHue`). The lane dash is the secondary cue.
    private func eventColor(for edge: GraphEdge) -> Color {
        Color(hue: edge.stableHue, saturation: 0.60, brightness: 0.82)
    }

    /// A per-lane dash so parallel same-pair edges stay distinguishable even when their event colours
    /// happen to be similar. Lane 0 (and any single edge) stays solid.
    private func laneDash(index: Int, count: Int) -> [CGFloat] {
        guard count > 1, index > 0 else { return [] }
        switch index % 4 {
        case 1: return [7, 4]
        case 2: return [2, 3]
        default: return [7, 3, 2, 3]
        }
    }

    private func drawRoutedEdge(in context: inout GraphicsContext, route: EdgeRoute, color: Color, width: CGFloat, dash: [CGFloat]) {
        let pts = route.points
        guard pts.count >= 2 else { return }
        let end = pts[pts.count - 1], prev = pts[pts.count - 2]
        let dx = end.x - prev.x, dy = end.y - prev.y
        let len = max(hypot(dx, dy), 1)
        let unit = CGPoint(x: dx / len, y: dy / len)
        // Pull the stroke back so it meets the arrowhead base, not the tip.
        let lineEnd = CGPoint(x: end.x - unit.x * style.arrowLength, y: end.y - unit.y * style.arrowLength)
        var path = Path()
        path.addLines(Array(pts.dropLast()) + [lineEnd])   // orthogonal polyline; rounded joins soften corners
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
        drawArrowhead(in: &context, tip: end, direction: unit, color: color)
    }

    /// Draws the label rotated along the edge tangent (already flipped upright by the router), the pill
    /// outlined in the edge colour so it reads as belonging to that line.
    private func drawRoutedLabel(in context: inout GraphicsContext, text: String, at anchor: CGPoint, angle: CGFloat, tint: Color) {
        context.drawLayer { layer in
            layer.translateBy(x: anchor.x, y: anchor.y)
            layer.rotate(by: .radians(Double(angle)))
            let resolved = layer.resolve(
                Text(text)
                    .font(.system(size: style.edgeLabelFontSize, weight: .medium))
                    .foregroundStyle(style.edgeLabelColor)
            )
            let ts = resolved.measure(in: CGSize(width: 400, height: 100))
            let pad: CGFloat = 4
            let bg = CGRect(x: -ts.width / 2 - pad, y: -ts.height / 2 - pad / 2, width: ts.width + pad * 2, height: ts.height + pad)
            let pill = Path(roundedRect: bg, cornerRadius: 4)
            layer.fill(pill, with: .color(style.edgeLabelBackground))
            layer.stroke(pill, with: .color(tint), lineWidth: 1.5)
            layer.draw(resolved, at: .zero, anchor: .center)
        }
    }

    // MARK: Initial-state indicators

    private func drawInitialIndicators(in context: inout GraphicsContext) {
        for node in model.nodes where node.isInitialChild {
            guard let rect = layout.frame(node.id) else { continue }
            let target = CGPoint(x: rect.minX, y: rect.midY)
            let dot = CGPoint(x: rect.minX - style.initialDotRadius * 3.2, y: rect.midY)
            let circle = CGRect(
                x: dot.x - style.initialDotRadius, y: dot.y - style.initialDotRadius,
                width: style.initialDotRadius * 2, height: style.initialDotRadius * 2
            )
            context.fill(Path(ellipseIn: circle), with: .color(style.initialDotColor))
            var line = Path()
            line.move(to: CGPoint(x: dot.x + style.initialDotRadius, y: dot.y))
            line.addLine(to: target)
            context.stroke(line, with: .color(style.initialDotColor), lineWidth: 1.6)
            drawArrowhead(in: &context, tip: target, direction: CGPoint(x: 1, y: 0), color: style.initialDotColor)
        }
    }

    // MARK: Leaf nodes

    private func drawLeafNodes(in context: inout GraphicsContext, withShadow: Bool) {
        for node in model.nodes where !node.type.isContainer {
            guard let rect = layout.frame(node.id) else { continue }
            let isActive = activeIDs.contains(node.id)
            let isSelected = node.id == selectedID

            let fill: Color
            let stroke: Color
            let textColor: Color
            switch node.type {
            case .final:
                fill = isActive ? style.activeNodeFill : style.finalNodeFill
                stroke = isActive ? style.activeNodeStroke : style.finalNodeStroke
                textColor = isActive ? style.activeNodeTextColor : style.finalNodeTextColor
            case .history:
                fill = style.historyNodeFill
                stroke = style.idleNodeStroke
                textColor = style.idleNodeTextColor
            default:
                fill = isActive ? style.activeNodeFill : style.idleNodeFill
                stroke = isActive ? style.activeNodeStroke : style.idleNodeStroke
                textColor = isActive ? style.activeNodeTextColor : style.idleNodeTextColor
            }

            let shape = Path(roundedRect: rect, cornerRadius: style.nodeCornerRadius)

            if withShadow, style.nodeShadowRadius > 0 {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(
                        color: .black.opacity(style.nodeShadowOpacity),
                        radius: style.nodeShadowRadius, x: 0, y: 1
                    ))
                    layer.fill(shape, with: .color(fill))
                }
            } else {
                context.fill(shape, with: .color(fill))
            }

            if isActive, style.activeNodeGlowRadius > 0 {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: style.activeNodeFill.opacity(0.9), radius: style.activeNodeGlowRadius))
                    layer.stroke(shape, with: .color(style.activeNodeStroke), lineWidth: style.nodeBorderWidth)
                }
            }

            let borderColor = isSelected ? style.selectedNodeStroke : stroke
            let borderWidth = isSelected ? style.selectedNodeStrokeWidth : style.nodeBorderWidth
            context.stroke(shape, with: .color(borderColor), lineWidth: borderWidth)

            // Final states get a thin inner ring.
            if node.type == .final {
                let inner = rect.insetBy(dx: 4, dy: 4)
                context.stroke(
                    Path(roundedRect: inner, cornerRadius: max(style.nodeCornerRadius - 3, 2)),
                    with: .color(stroke), lineWidth: 1
                )
            }

            let label = Text(node.label)
                .font(.system(size: style.nodeLabelFontSize, weight: style.nodeLabelWeight))
                .foregroundStyle(textColor)
            context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
        }
    }

    // MARK: Geometry helpers

    private func borderIntersection(rect: CGRect, toward point: CGPoint) -> CGPoint {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - c.x, dy = point.y - c.y
        if dx == 0 && dy == 0 { return c }
        let hw = rect.width / 2, hh = rect.height / 2
        let sx = dx == 0 ? CGFloat.greatestFiniteMagnitude : hw / abs(dx)
        let sy = dy == 0 ? CGFloat.greatestFiniteMagnitude : hh / abs(dy)
        let s = min(sx, sy)
        return CGPoint(x: c.x + dx * s, y: c.y + dy * s)
    }
}

// MARK: - Hit testing (shared with the gesture handlers)

extension GraphLayoutResult {
    /// Returns the id of the smallest leaf-ish frame containing `logicalPoint`,
    /// preferring deeper/smaller frames so dragging grabs the node, not its container.
    func hitTest(_ logicalPoint: CGPoint, model: GraphModel, preferLeaves: Bool = true) -> String? {
        var best: String?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for (id, frame) in frames where frame.contains(logicalPoint) {
            if preferLeaves, model.node(id)?.type.isContainer == true, model.children(of: id).isEmpty == false {
                // Skip containers when a child also matches; handled by area preference below.
            }
            let area = frame.width * frame.height
            if area < bestArea {
                bestArea = area
                best = id
            }
        }
        return best
    }

    /// Returns the id of the routed edge nearest `logicalPoint` (by label pill or curve), or `nil` if
    /// none is within `threshold`. Label anchors are given a slight bias so grabbing a pill is easy.
    /// Only meaningful under auto-layout (routes are empty otherwise).
    func hitTestEdge(_ logicalPoint: CGPoint, threshold: CGFloat) -> String? {
        func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let l2 = dx * dx + dy * dy
            if l2 < 1e-9 { return d(p, a) }
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
            return d(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
        }
        var best: String?
        var bestDist = threshold
        for (id, route) in routes {
            // Prefer the label pill (bias by 8) so dragging the label is forgiving.
            if route.labelWidth > 0 {
                let dl = d(route.labelAnchor, logicalPoint) - 8
                if dl < bestDist { bestDist = dl; best = id }
            }
            let pts = route.points
            guard pts.count >= 2 else { continue }
            for k in 0..<(pts.count - 1) {
                let dist = distToSegment(logicalPoint, pts[k], pts[k + 1])
                if dist < bestDist { bestDist = dist; best = id }
            }
        }
        return best
    }
}
#endif
