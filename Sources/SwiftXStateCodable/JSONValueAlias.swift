import SwiftXState

/// Within this module, bare `JSONValue` means **SwiftXState's** tree (`.number(Double)`), which the
/// persistence, replay, and params APIs use. Disambiguates it from FridayTheThirteenth's `JSONValue`
/// (re-exported via FridayTheCodable) — a module-local typealias wins over both imports.
public typealias JSONValue = SwiftXState.JSONValue
