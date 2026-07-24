// A deterministic CPU burn used to *demonstrate* real cross-worker parallelism: run it on
// two workers at once and it finishes in ~max(t), not ~sum(t), because each Web Worker is a
// separate OS thread. The returned checksum keeps the optimizer from deleting the loop.
//
// (No large `Int` literals — `Int` is 32-bit on wasm32, so the arithmetic stays in `UInt32`.)
func spin(_ rounds: Int) -> Int {
    var acc: UInt32 = 2166136261            // FNV-1a offset basis
    var i = 0
    while i < rounds {
        acc = (acc ^ UInt32(truncatingIfNeeded: i)) &* 16777619   // FNV-1a prime
        i &+= 1
    }
    return Int(acc & 0x7fff_ffff)
}
