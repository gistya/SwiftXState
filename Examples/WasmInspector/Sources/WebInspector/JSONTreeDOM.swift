import JavaScriptKit
import SwiftXState
import SwiftXStateInspectorCore

/// Renders a `JSONValue` as a native `<details>`/`<summary>` disclosure tree — monospace,
/// color-coded by kind, touch-friendly (the whole summary row toggles). Reuses the JSON-tree
/// helpers from `SwiftXStateInspectorCore`, so it categorizes/labels values exactly like the
/// native inspector's `JSONTreeView`.
@MainActor
enum JSONTreeDOM {
    /// Build a tree element for `value`. `expandedDepth` controls how many levels start open.
    static func render(_ value: JSONValue, label: String? = nil, expandedDepth: Int = 2) -> JSValue {
        let root = DOM.el("div", "json-tree")
        build(into: root, key: label, value: value, depth: 0, expandedDepth: expandedDepth)
        return root
    }

    private static func build(into parent: JSValue, key: String?, value: JSONValue, depth: Int, expandedDepth: Int) {
        if value.isExpandable {
            let details = DOM.el("details", "json-branch")
            if depth < expandedDepth { _ = details.setAttribute("open", "") }

            let summary = DOM.el("summary", "json-summary")
            if let key { DOM.append(summary, DOM.el("span", "json-key", text: key + ": ")) }
            DOM.append(summary, DOM.el("span", "json-type", text: value.collapsedSummary()))
            DOM.append(details, summary)

            let box = DOM.el("div", "json-children")
            for (k, v) in value.treeChildren() {
                build(into: box, key: k, value: v, depth: depth + 1, expandedDepth: expandedDepth)
            }
            DOM.append(details, box)
            DOM.append(parent, details)
        } else {
            let leaf = DOM.el("div", "json-leaf")
            if let key { DOM.append(leaf, DOM.el("span", "json-key", text: key + ": ")) }
            DOM.append(leaf, DOM.el("span", "json-\(kindName(value.kind))", text: value.scalarText))
            DOM.append(parent, leaf)
        }
    }

    private static func kindName(_ k: JSONKind) -> String {
        switch k {
        case .object: return "object"
        case .array: return "array"
        case .string: return "string"
        case .number: return "number"
        case .bool: return "bool"
        case .null: return "null"
        }
    }
}
