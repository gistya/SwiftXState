import FridayTheCodable
import SwiftXState

/// SwiftXState's `Codable` adapter layer.
///
/// The core `SwiftXState` module is deliberately free of any JSON *engine* — it serializes
/// ``JSONValue`` with a hand-rolled, dependency-free writer/parser so machine export, import, and
/// the runtime all work under Embedded Swift. Everything that needs the `Codable` machinery (and
/// therefore `FridayTheCodable`) lives here instead: persistence, replay serialization, the
/// `Encodable`→``JSONValue`` bridge, and parameterized guard/action payloads.
///
/// This mirrors how `FridayTheThirteenth` (the engine, over `JSONValue`) is split from
/// `FridayTheCodable` (the `Codable` adapters).
public enum SwiftXStateCodable {}

extension FridayJSONEncoder {
    /// SwiftXState's standard JSON encoder. `writeWholeFloatsAsIntegers` mirrors the core's
    /// hand-rolled writer (a whole `Double` like `5.0` is written `5`) and — crucially — lets a
    /// `JSONValue.number(Double)` round-trip back into an `Int`-typed `Codable`, since
    /// FridayTheThirteenth decodes integers strictly (a JSON float won't decode into `Int`).
    static var swiftXState: FridayJSONEncoder {
        FridayJSONEncoder(outputFormatting: JSONSerializeOptions(writeWholeFloatsAsIntegers: true))
    }

    /// As ``swiftXState`` but with sorted keys, for deterministic output.
    static var swiftXStateSorted: FridayJSONEncoder {
        FridayJSONEncoder(outputFormatting: JSONSerializeOptions(sortedKeys: true, writeWholeFloatsAsIntegers: true))
    }
}
