/// A random UUID-v4 string generated for actor / child identifiers on every target.
///
/// 122 random bits from the stdlib `SystemRandomNumberGenerator`, formatted `8-4-4-4-12` with the
/// version (4) and variant (1) bits set, using a manual hex table.
@inlinable
func randomUUIDString() -> String {
    var rng = SystemRandomNumberGenerator()
    var bytes = [UInt8]()
    bytes.reserveCapacity(16)
    for _ in 0..<16 { bytes.append(.random(in: .min ... .max, using: &rng)) }
    bytes[6] = (bytes[6] & 0x0F) | 0x40   // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant 1 (RFC 4122)

    let hex: [Character] = Array("0123456789abcdef")
    let dashAfter: Set<Int> = [4, 6, 8, 10]   // insert "-" after these byte counts
    var out = ""
    out.reserveCapacity(36)
    for (index, byte) in bytes.enumerated() {
        out.append(hex[Int(byte >> 4)])
        out.append(hex[Int(byte & 0x0F)])
        if dashAfter.contains(index + 1) { out.append("-") }
    }
    return out
}
