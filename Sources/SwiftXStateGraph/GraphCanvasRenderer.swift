#if SWIFTXSTATE_GRAPH_UI
import SwiftUI

/// Maps between screen (viewport) coordinates and the graph's logical coordinate
/// space, given the current zoom/pan. The transform anchors the content's bounds
/// center at the viewport center plus the pan offset:
///
///     screen = (logical - center) * zoom + viewport/2 + pan
struct GraphTransform {
    var zoom: CGFloat
    var pan: CGSize
    var viewport: CGSize
    var center: CGPoint

    func screen(from logical: CGPoint) -> CGPoint {
        CGPoint(
            x: (logical.x - center.x) * zoom + viewport.width / 2 + pan.width,
            y: (logical.y - center.y) * zoom + viewport.height / 2 + pan.height
        )
    }

    func logical(from screen: CGPoint) -> CGPoint {
        CGPoint(
            x: (screen.x - viewport.width / 2 - pan.width) / zoom + center.x,
            y: (screen.y - viewport.height / 2 - pan.height) / zoom + center.y
        )
    }
}

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
        // Fan out edges that share an endpoint pair so duplicates / back-edges don't overlap.
        let ordered = model.edges.sorted { $0.id < $1.id }
        var laneCount: [String: Int] = [:]
        for edge in ordered { laneCount[pairKey(edge), default: 0] += 1 }
        var laneSeen: [String: Int] = [:]

        for edge in ordered {
            guard let fromRect = layout.frame(edge.from), let toRect = layout.frame(edge.to) else { continue }
            let emphasized = edge.from == selectedID || edge.to == selectedID
            let color = emphasized ? style.activeEdgeColor : style.edgeColor
            let width = emphasized ? style.activeEdgeWidth : style.edgeWidth
            let dash = edge.isGuarded ? style.guardedEdgeDash : []

            let key = pairKey(edge)
            let lane = laneSeen[key, default: 0]
            laneSeen[key] = lane + 1
            let lanes = laneCount[key, default: 1]

            if edge.isSelfLoop {
                drawSelfLoop(in: &context, rect: fromRect, edge: edge, color: color, width: width, dash: dash, showLabel: showLabels)
                continue
            }

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
        color: Color, width: CGFloat, dash: [CGFloat], showLabel: Bool
    ) {
        let r = style.selfLoopRadius
        let anchor = CGPoint(x: rect.midX, y: rect.minY)
        let left = CGPoint(x: anchor.x - r * 0.5, y: anchor.y)
        let right = CGPoint(x: anchor.x + r * 0.5, y: anchor.y)
        var path = Path()
        path.move(to: left)
        path.addCurve(
            to: right,
            control1: CGPoint(x: anchor.x - r, y: anchor.y - r * 1.6),
            control2: CGPoint(x: anchor.x + r, y: anchor.y - r * 1.6)
        )
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        drawArrowhead(in: &context, tip: right, direction: CGPoint(x: 0.2, y: 1), color: color)
        if showLabel, !edge.label.isEmpty {
            drawEdgeLabel(in: &context, text: edge.label, at: CGPoint(x: anchor.x, y: anchor.y - r * 1.5))
        }
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

    private func drawEdgeLabel(in context: inout GraphicsContext, text: String, at point: CGPoint) {
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
        context.fill(Path(roundedRect: bg, cornerRadius: 4), with: .color(style.edgeLabelBackground))
        context.draw(resolved, at: point, anchor: .center)
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
}
#endif
