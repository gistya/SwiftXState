#if SWIFTXSTATE_INSPECTOR_UI
import SwiftUI
import SwiftXState

/// A recursive, syntax-colored JSON tree with disclosure triangles — the inspector's
/// equivalent of the expandable data view in the Stately Inspector.
///
/// Touch-first: each row is a full-width tap target (no hover dependency). Expansion is
/// tracked by JSON *path*, so it survives live data updates (a new snapshot keeps the
/// same nodes open). Rendering is a flattened `LazyVStack`, so large objects/arrays
/// (e.g. a 32-entry `occupants` map) stay smooth.
public struct JSONTreeView: View {
    private let value: JSONValue
    private let rootLabel: String?
    private let defaultExpandedDepth: Int

    @Environment(\.inspectorStyle) private var style
    @State private var expanded: Set<String>

    public init(_ value: JSONValue, rootLabel: String? = nil, defaultExpandedDepth: Int = 1) {
        self.value = value
        self.rootLabel = rootLabel
        self.defaultExpandedDepth = defaultExpandedDepth
        // Seed expansion at init (not onAppear) so content is open on first render — and so
        // it works under ImageRenderer / snapshots.
        _expanded = State(initialValue: Self.seedExpansion(value, depth: defaultExpandedDepth))
    }

    public var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                rowView(row)
            }
        }
        .font(style.monoFont)
    }

    // MARK: Flattened rows

    private struct Row: Identifiable {
        let id: String          // JSON path
        let depth: Int
        let key: String?
        let value: JSONValue
        let isExpandable: Bool
        let isExpanded: Bool
    }

    private var rows: [Row] {
        var out: [Row] = []
        func walk(_ value: JSONValue, key: String?, path: String, depth: Int) {
            let expandable = value.isExpandable
            let isOpen = expanded.contains(path)
            out.append(Row(id: path, depth: depth, key: key, value: value, isExpandable: expandable, isExpanded: isOpen))
            guard expandable, isOpen else { return }
            for child in value.treeChildren() {
                walk(child.value, key: child.key, path: "\(path)/\(child.key)", depth: depth + 1)
            }
        }
        walk(value, key: rootLabel, path: "root", depth: 0)
        return out
    }

    // MARK: Row rendering

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Spacer().frame(width: CGFloat(row.depth) * style.indentWidth)

            if row.isExpandable {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: style.disclosureSize, weight: .semibold))
                    .foregroundStyle(style.secondaryText)
                    .frame(width: style.disclosureSize + 4)
            } else {
                Spacer().frame(width: style.disclosureSize + 4)
            }

            if let key = row.key {
                Text(key + ":")
                    .foregroundStyle(style.keyColor)
            }

            valueText(row)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .frame(minHeight: style.rowMinHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard row.isExpandable else { return }
            if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
        }
    }

    @ViewBuilder
    private func valueText(_ row: Row) -> some View {
        switch row.value.kind {
        case .object, .array:
            if row.isExpanded {
                Text(row.value.typeName).foregroundStyle(style.summaryColor).italic()
            } else {
                Text(row.value.collapsedSummary()).foregroundStyle(style.summaryColor).italic()
            }
        case .string:
            Text(row.value.scalarText).foregroundStyle(style.stringColor)
        case .number:
            Text(row.value.scalarText).foregroundStyle(style.numberColor)
        case .bool:
            Text(row.value.scalarText).foregroundStyle(style.boolColor)
        case .null:
            Text("null").foregroundStyle(style.nullColor)
        }
    }

    // MARK: Default expansion

    private static func seedExpansion(_ value: JSONValue, depth defaultExpandedDepth: Int) -> Set<String> {
        var seed: Set<String> = []
        func walk(_ value: JSONValue, path: String, depth: Int) {
            guard value.isExpandable, depth < defaultExpandedDepth else { return }
            seed.insert(path)
            for child in value.treeChildren() {
                walk(child.value, path: "\(path)/\(child.key)", depth: depth + 1)
            }
        }
        walk(value, path: "root", depth: 0)
        return seed
    }
}
#endif
