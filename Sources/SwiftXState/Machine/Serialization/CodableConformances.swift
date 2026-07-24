// MARK: - Codable conformance policy
//
// Every `Codable` conformance in the core is written as a separate extension behind
// `#if !hasFeature(Embedded)`, never on the type declaration itself. Two reasons:
//
//  1. **Embedded Swift has no `Codable`.** Isolating the conformances means the Embedded exclusion
//     is a single guard per type, and adding a new wire type cannot silently reintroduce a blocker.
//  2. **The core never encodes or decodes anything.** These conformances exist purely so downstream
//     consumers (`SwiftXStateCodable`, `SwiftXStateInspect`, user code) can serialize these types.
//     Nothing in the core calls an encoder or decoder, so dropping them on Embedded costs no core
//     functionality — `definitionJSON()` and inspection go through the hand-rolled `JSONValueCodec`
//     instead, which needs neither `Codable` nor reflection.
//
// **Where a conformance must live.** Swift only synthesizes `Codable` from the *same file* as the
// declaration, with one exception: a raw-value enum derives its conformance from `RawRepresentable`
// and so can be extended from anywhere in the module. Those are collected here; every other type
// carries its own guarded extension beside its declaration. Hand-written conformances (`JSONValue`,
// `PersistedChildSnapshot`, `ReplayableEvent`) likewise stay beside their implementations, behind
// the same guard.

#if !hasFeature(Embedded)

// Raw-value enums — conformance comes from `RawRepresentable`, so these may live out-of-file.
extension SystemEvent: Codable {}
extension InspectionEventKind: Codable {}
extension OpaqueInvokeRestorePolicy: Codable {}

#endif
