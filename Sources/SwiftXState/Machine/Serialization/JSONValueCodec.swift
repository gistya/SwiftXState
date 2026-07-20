// A dependency-free JSON reader/writer for ``JSONValue``.
//
// This is the Embedded-safe half of SwiftXState's JSON story: it uses no `Codable`, no reflection,
// no Foundation, and no third-party engine — just a walk over the `JSONValue` tree (writing) and a
// recursive-descent scan over UTF-8 bytes (reading). `definitionJSON()` export and
// `MachineSimulator` import both bottom out here, so they stay available to Embedded clients.
//
// Output is byte-compatible with the previous `FridayJSONEncoder.swiftXStateSorted` configuration:
// compact (no insignificant whitespace), **sorted object keys** (deterministic machine definitions),
// and whole `Double`s written as integers (`5.0` → `5`) — the latter matters because a
// `JSONValue.number(Double)` must round-trip back into an `Int`-typed field.

// MARK: - Writing

public extension JSONValue {
    /// Serialize to compact JSON with sorted object keys. Deterministic — the same tree always
    /// produces the same string.
    func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case let .bool(value):
            out += value ? "true" : "false"
        case let .number(value):
            out += JSONValue.formatNumber(value)
        case let .string(value):
            JSONValue.writeString(value, into: &out)
        case let .array(values):
            out += "["
            var first = true
            for element in values {
                if !first { out += "," }
                first = false
                element.write(into: &out)
            }
            out += "]"
        case let .object(fields):
            out += "{"
            var first = true
            for key in fields.keys.sorted() {
                if !first { out += "," }
                first = false
                JSONValue.writeString(key, into: &out)
                out += ":"
                fields[key]?.write(into: &out)
            }
            out += "}"
        }
    }

    /// Whole doubles are written as integers so a `.number(Double)` survives a round-trip into an
    /// `Int`-typed field. JSON has no NaN/Infinity, so those degrade to `null`.
    private static func formatNumber(_ value: Double) -> String {
        if value.isNaN || value.isInfinite { return "null" }
        // 2^53 — beyond this a Double can no longer represent consecutive integers exactly.
        if value == value.rounded(), value.magnitude < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static let hexDigits: [Character] = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
    ]

    private static func writeString(_ string: String, into out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += "\\u00"
                    out.append(hexDigits[Int((scalar.value >> 4) & 0xF)])
                    out.append(hexDigits[Int(scalar.value & 0xF)])
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - Reading

public extension JSONValue {
    /// Parse a JSON document. Returns `nil` if the text isn't valid JSON or has trailing content.
    static func parse(_ text: String) -> JSONValue? {
        var scanner = JSONScanner(bytes: Array(text.utf8))
        guard let value = scanner.parseValue() else { return nil }
        scanner.skipWhitespace()
        guard scanner.isAtEnd else { return nil }
        return value
    }
}

/// Recursive-descent scanner over UTF-8 bytes. Deliberately allocation-light and free of any
/// Foundation / Codable machinery.
private struct JSONScanner {
    let bytes: [UInt8]
    var index: Int = 0

    var isAtEnd: Bool { index >= bytes.count }
    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard let byte = current else { return nil }
        switch byte {
        case UInt8(ascii: "{"): return parseObject()
        case UInt8(ascii: "["): return parseArray()
        case UInt8(ascii: "\""): return parseString().map(JSONValue.string)
        case UInt8(ascii: "t"): return match("true") ? .bool(true) : nil
        case UInt8(ascii: "f"): return match("false") ? .bool(false) : nil
        case UInt8(ascii: "n"): return match("null") ? .null : nil
        default: return parseNumber()
        }
    }

    private mutating func match(_ literal: String) -> Bool {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count else { return false }
        for (offset, byte) in expected.enumerated() where bytes[index + offset] != byte {
            return false
        }
        index += expected.count
        return true
    }

    private mutating func parseObject() -> JSONValue? {
        index += 1                                   // consume '{'
        var fields: [String: JSONValue] = [:]
        skipWhitespace()
        if current == UInt8(ascii: "}") { index += 1; return .object(fields) }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\""), let key = parseString() else { return nil }
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { return nil }
            index += 1
            guard let value = parseValue() else { return nil }
            fields[key] = value
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(fields)
            default: return nil
            }
        }
    }

    private mutating func parseArray() -> JSONValue? {
        index += 1                                   // consume '['
        var elements: [JSONValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") { index += 1; return .array(elements) }
        while true {
            guard let value = parseValue() else { return nil }
            elements.append(value)
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(elements)
            default: return nil
            }
        }
    }

    private mutating func parseString() -> String? {
        index += 1                                   // consume opening quote
        var scalars = String.UnicodeScalarView()
        while let byte = current {
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(scalars)
            case UInt8(ascii: "\\"):
                index += 1
                guard let escape = current else { return nil }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    guard let scalar = parseUnicodeEscape() else { return nil }
                    scalars.append(scalar)
                default: return nil
                }
            default:
                // Copy the raw UTF-8 sequence through untouched.
                let start = index
                while let byte = current, byte != UInt8(ascii: "\""), byte != UInt8(ascii: "\\") {
                    index += 1
                }
                let chunk = String(decoding: bytes[start ..< index], as: UTF8.self)
                scalars.append(contentsOf: chunk.unicodeScalars)
            }
        }
        return nil                                   // unterminated
    }

    /// Reads the 4 hex digits after `\u`, joining a surrogate pair if one follows.
    private mutating func parseUnicodeEscape() -> Unicode.Scalar? {
        guard let high = readHex4() else { return nil }
        if high >= 0xD800, high <= 0xDBFF {
            guard index + 1 < bytes.count,
                  bytes[index] == UInt8(ascii: "\\"),
                  bytes[index + 1] == UInt8(ascii: "u")
            else { return Unicode.Scalar(0xFFFD) }
            index += 2
            guard let low = readHex4(), low >= 0xDC00, low <= 0xDFFF else { return Unicode.Scalar(0xFFFD) }
            let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
            return Unicode.Scalar(combined) ?? Unicode.Scalar(0xFFFD)
        }
        return Unicode.Scalar(high) ?? Unicode.Scalar(0xFFFD)
    }

    private mutating func readHex4() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for _ in 0 ..< 4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a") ... UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A") ... UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
            default: return nil
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() -> JSONValue? {
        let start = index
        if current == UInt8(ascii: "-") { index += 1 }
        while let byte = current,
              (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
              || byte == UInt8(ascii: ".")
              || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
              || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
        {
            index += 1
        }
        guard start < index else { return nil }
        let text = String(decoding: bytes[start ..< index], as: UTF8.self)
        guard let value = Double(text) else { return nil }
        return .number(value)
    }
}
