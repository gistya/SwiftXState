import Testing
@testable import SwiftXState

@Suite("Context deltas (Diff Mode)")
struct ContextDeltaTests {
    /// The core contract: applying a delta to the old value reproduces the new value exactly.
    private func expectRoundTrip(_ old: JSONValue, _ new: JSONValue, sourceLocation: SourceLocation = #_sourceLocation) {
        let delta = ContextDelta.between(old, new)
        #expect(delta.applied(to: old) == new, sourceLocation: sourceLocation)
    }

    @Test("identical values produce no delta")
    func unchanged() {
        let value = JSONValue.object(["count": .number(1), "name": .string("a")])
        #expect(ContextDelta.between(value, value) == .unchanged)
        expectRoundTrip(value, value)
    }

    @Test("only changed keys appear in the delta")
    func onlyChangedKeys() {
        let old = JSONValue.object(["count": .number(1), "name": .string("a"), "big": .string("unchanged")])
        let new = JSONValue.object(["count": .number(2), "name": .string("a"), "big": .string("unchanged")])

        guard case let .merge(fields) = ContextDelta.between(old, new) else {
            Issue.record("expected a merge delta")
            return
        }
        #expect(fields.count == 1)                 // `name` and `big` are not resent
        #expect(fields["count"] == .replace(.number(2)))
        expectRoundTrip(old, new)
    }

    @Test("added and removed keys round-trip")
    func addedAndRemoved() {
        let old = JSONValue.object(["a": .number(1), "gone": .string("x")])
        let new = JSONValue.object(["a": .number(1), "added": .bool(true)])

        guard case let .merge(fields) = ContextDelta.between(old, new) else {
            Issue.record("expected a merge delta")
            return
        }
        #expect(fields["gone"] == .removed)
        #expect(fields["added"] == .replace(.bool(true)))
        expectRoundTrip(old, new)
    }

    /// The reason this isn't RFC 7386 Merge Patch: `null` is a real value, not a deletion.
    @Test("a field set to null is distinct from a removed field")
    func nullIsNotRemoval() {
        let old = JSONValue.object(["a": .number(1)])
        let setToNull = JSONValue.object(["a": .null])
        let removed = JSONValue.object([:])

        #expect(ContextDelta.between(old, setToNull) == .merge(["a": .replace(.null)]))
        #expect(ContextDelta.between(old, removed) == .merge(["a": .removed]))
        expectRoundTrip(old, setToNull)
        expectRoundTrip(old, removed)
    }

    @Test("nested objects recurse; only the changed leaf travels")
    func nestedRecursion() {
        let old = JSONValue.object(["user": .object(["id": .number(1), "name": .string("ada")])])
        let new = JSONValue.object(["user": .object(["id": .number(1), "name": .string("grace")])])

        #expect(ContextDelta.between(old, new) == .merge(["user": .merge(["name": .replace(.string("grace"))])]))
        expectRoundTrip(old, new)
    }

    @Test("arrays are replaced atomically")
    func arraysAreAtomic() {
        let old = JSONValue.object(["items": .array([.number(1), .number(2)])])
        let new = JSONValue.object(["items": .array([.number(1), .number(3)])])

        #expect(ContextDelta.between(old, new) == .merge(["items": .replace(.array([.number(1), .number(3)]))]))
        expectRoundTrip(old, new)
    }

    @Test("a change of shape replaces wholesale")
    func shapeChange() {
        expectRoundTrip(.object(["a": .number(1)]), .string("now a string"))
        expectRoundTrip(.string("was a string"), .object(["a": .number(1)]))
        expectRoundTrip(.null, .object(["a": .number(1)]))
    }

    @Test("the wire form round-trips")
    func wireRoundTrip() {
        let old = JSONValue.object(["a": .number(1), "gone": .string("x"), "n": .object(["k": .bool(false)])])
        let new = JSONValue.object(["a": .number(2), "n": .object(["k": .bool(true)]), "added": .null])
        let delta = ContextDelta.between(old, new)

        let decoded = ContextDelta.fromJSON(delta.jsonValue())
        #expect(decoded == delta)
        #expect(decoded?.applied(to: old) == new)
    }

    @Test("a delta is smaller than the full context it replaces")
    func deltaIsSmaller() {
        var fields: [String: JSONValue] = [:]
        for i in 0 ..< 50 { fields["field\(i)"] = .string("a fairly long unchanging value \(i)") }
        let old = JSONValue.object(fields)
        fields["field7"] = .string("changed")
        let new = JSONValue.object(fields)

        let full = new.serialized().utf8.count
        let delta = ContextDelta.between(old, new).jsonValue().serialized().utf8.count
        #expect(delta < full / 10, "a one-field change should be far smaller than the whole context")
        expectRoundTrip(old, new)
    }
}
