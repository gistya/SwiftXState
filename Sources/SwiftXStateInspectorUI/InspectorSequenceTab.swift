#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI
import SwiftXState

/// Sequence diagram: actors as vertical lifelines, events as arrows between them over
/// time (oldest at top). Snapshots appear as small state markers on a lifeline. With many
/// actors (e.g. the 96-actor stress test) only the lifelines touched by the recent window
/// are shown, so the diagram stays legible while the Actors tab carries the full list.
struct InspectorSequenceTab: View {
    let store: InspectorStore
    @Environment(\.inspectorStyle) private var style

    private let maxEvents = 160
    private let maxColumns = 14
    private let columnWidth: CGFloat = 150
    private let rowHeight: CGFloat = 34
    private let headerHeight: CGFloat = 52
    private let externalKey = "·external·"

    var body: some View {
        let events = Array(store.feed.suffix(maxEvents))
        let columns = columnOrder(for: events)

        if columns.count <= 1 {
            ContentUnavailableView_Compat(
                title: "Sequence diagram",
                systemImage: "arrow.left.arrow.right",
                message: "Send events between actors to populate the diagram."
            )
            .background(style.background)
        } else {
            ScrollView([.vertical, .horizontal]) {
                Canvas { context, _ in
                    draw(context: &context, events: events, columns: columns)
                }
                .frame(
                    width: max(CGFloat(columns.count) * columnWidth, 200),
                    height: headerHeight + CGFloat(events.count) * rowHeight + 20
                )
            }
            .background(style.background)
        }
    }

    // MARK: Columns

    private func columnLabel(_ key: String) -> String {
        key == externalKey ? "external" : (store.actor(key)?.displayName ?? key)
    }

    /// Lifelines actually referenced by the recent events, capped for legibility.
    private func columnOrder(for events: [FeedEntry]) -> [String] {
        var seen: [String] = []
        var set = Set<String>()
        func add(_ key: String) { if set.insert(key).inserted { seen.append(key) } }
        for entry in events {
            if let source = entry.sourceSessionID { add(source) } else if entry.kind == .event { add(externalKey) }
            add(entry.sessionID)
        }
        return Array(seen.prefix(maxColumns))
    }

    // MARK: Drawing

    private func draw(context: inout GraphicsContext, events: [FeedEntry], columns: [String]) {
        var x: [String: CGFloat] = [:]
        for (i, key) in columns.enumerated() { x[key] = CGFloat(i) * columnWidth + columnWidth / 2 }
        let totalHeight = headerHeight + CGFloat(events.count) * rowHeight + 20

        // Lifelines + headers.
        for key in columns {
            guard let cx = x[key] else { continue }
            var line = Path()
            line.move(to: CGPoint(x: cx, y: headerHeight - 8))
            line.addLine(to: CGPoint(x: cx, y: totalHeight - 8))
            context.stroke(line, with: .color(style.divider), lineWidth: 1)

            let header = Text(columnLabel(key))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(key == externalKey ? style.secondaryText : style.primaryText)
            let box = CGRect(x: cx - columnWidth / 2 + 8, y: 8, width: columnWidth - 16, height: 30)
            context.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(style.panelBackground))
            context.draw(header, at: CGPoint(x: cx, y: 23), anchor: .center)
        }

        // Events, oldest at top.
        for (i, entry) in events.enumerated() {
            let y = headerHeight + CGFloat(i) * rowHeight + rowHeight / 2
            guard let targetX = x[entry.sessionID] else { continue }

            switch entry.kind {
            case .event:
                let sourceKey = entry.sourceSessionID ?? externalKey
                guard let sourceX = x[sourceKey] else { continue }
                drawArrow(&context, fromX: sourceX, toX: targetX, y: y,
                          label: entry.eventType ?? "(event)", color: style.eventKindColor)
            case .snapshot, .transition:
                drawMarker(&context, x: targetX, y: y,
                           label: entry.snapshot.map { compactValue($0.stateValue) } ?? "",
                           color: style.snapshotKindColor)
            case .actor:
                drawMarker(&context, x: targetX, y: y, label: "start", color: style.actorKindColor)
            default:
                break
            }
        }
    }

    private func drawArrow(_ context: inout GraphicsContext, fromX: CGFloat, toX: CGFloat, y: CGFloat, label: String, color: Color) {
        if abs(fromX - toX) < 1 {
            // Self-message loop.
            drawMarker(&context, x: fromX, y: y, label: label, color: color)
            return
        }
        var line = Path()
        line.move(to: CGPoint(x: fromX, y: y))
        line.addLine(to: CGPoint(x: toX, y: y))
        context.stroke(line, with: .color(color), lineWidth: 1.4)

        let dir: CGFloat = toX > fromX ? 1 : -1
        var head = Path()
        head.move(to: CGPoint(x: toX, y: y))
        head.addLine(to: CGPoint(x: toX - dir * 7, y: y - 4))
        head.addLine(to: CGPoint(x: toX - dir * 7, y: y + 4))
        head.closeSubpath()
        context.fill(head, with: .color(color))

        let text = Text(label).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(style.primaryText)
        let resolved = context.resolve(text)
        let size = resolved.measure(in: CGSize(width: 400, height: 40))
        let midX = (fromX + toX) / 2
        let bg = CGRect(x: midX - size.width / 2 - 4, y: y - size.height - 3, width: size.width + 8, height: size.height + 2)
        context.fill(Path(roundedRect: bg, cornerRadius: 4), with: .color(style.background.opacity(0.9)))
        context.draw(resolved, at: CGPoint(x: midX, y: y - size.height / 2 - 2), anchor: .center)
    }

    private func drawMarker(_ context: inout GraphicsContext, x: CGFloat, y: CGFloat, label: String, color: Color) {
        let text = Text(label).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(style.primaryText)
        let resolved = context.resolve(text)
        let size = resolved.measure(in: CGSize(width: 300, height: 30))
        let box = CGRect(x: x - size.width / 2 - 6, y: y - 9, width: size.width + 12, height: 18)
        context.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(color.opacity(0.22)))
        context.stroke(Path(roundedRect: box, cornerRadius: 5), with: .color(color), lineWidth: 1)
        context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .center)
    }

    private func compactValue(_ value: StateValue) -> String {
        let text = (try? JSONValue.encode(value.toJSONValue())) ?? value.description
        return text.count > 22 ? String(text.prefix(21)) + "…" : text
    }
}
#endif
