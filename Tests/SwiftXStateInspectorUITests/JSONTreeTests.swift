#if SWIFTXSTATE_INSPECTOR_UI
import Testing
@testable import SwiftXState
@testable import SwiftXStateInspectorUI

@Suite("JSONValue tree helpers")
struct JSONTreeTests {
    @Test("kind, expandability, and children")
    func basics() {
        let value: JSONValue = .object([
            "board": .object(["a1": .string("wRa1")]),
            "ply": .number(0),
            "turn": .string("white"),
            "outcome": .null,
            "moves": .array([.string("e4"), .string("e5")]),
        ])

        #expect(value.kind == .object)
        #expect(value.isExpandable)
        // Children are sorted by key.
        #expect(value.treeChildren().map(\.key) == ["board", "moves", "outcome", "ply", "turn"])

        #expect(JSONValue.number(0).scalarText == "0")
        #expect(JSONValue.number(1.5).scalarText == "1.5")
        #expect(JSONValue.string("hi").scalarText == "\"hi\"")
        #expect(JSONValue.null.isExpandable == false)
        #expect(JSONValue.array([.number(1), .number(2)]).typeName == "Array(2)")
        #expect(JSONValue.array([]).isExpandable == false)
    }

    @Test("array children are index-keyed in order")
    func arrayChildren() {
        let value: JSONValue = .array([.string("a"), .string("b"), .string("c")])
        #expect(value.treeChildren().map(\.key) == ["0", "1", "2"])
        #expect(value.treeChildren().map { $0.value.scalarText } == ["\"a\"", "\"b\"", "\"c\""])
    }

    @Test("collapsed object summary previews keys")
    func collapsedSummary() {
        let value: JSONValue = .object(["value": .object([:]), "context": .object([:]), "status": .null, "z": .null])
        let summary = value.collapsedSummary(maxKeys: 2)
        #expect(summary.hasPrefix("{"))
        #expect(summary.hasSuffix("…}"))
    }
}
#endif
