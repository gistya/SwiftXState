// Duration-string delays — a port of xstate's `parseDurationToMilliseconds`
// (xstate v6, packages/core/src/delay.ts). Delays (`after`, `timeout`) accept, in addition to a
// plain number of milliseconds:
//
//   "<int>ms"                                  e.g. "10ms"
//   "<num>s"   (up to 3 fractional digits → ms) e.g. "5s", "1.5s", "0.25s"
//   day-time ISO-8601  P[nW][nD]T[nH][nM][nS]   e.g. "PT2M", "P1DT2H30M", "PT1,5S"
//
// Year/month ISO components (`Y`, and `M` before `T`) are intentionally NOT accepted: a calendar
// month/year has no fixed millisecond length, so it's meaningless for a timer — matching xstate.
//
// Hand-rolled (no `Regex`/Foundation) so it works identically on macOS, Linux, Windows, Wasm and
// Embedded Swift. Returns nil for anything that isn't a recognized duration string.

func parseDurationToMilliseconds(_ duration: String) -> Int? {
    var c = Array(duration)
    while let f = c.first, f == " " || f == "\t" || f == "\n" || f == "\r" { c.removeFirst() }
    while let l = c.last,  l == " " || l == "\t" || l == "\n" || l == "\r" { c.removeLast() }
    guard !c.isEmpty else { return nil }

    if let ms = matchMilliseconds(c) { return ms }
    if let ms = matchSeconds(c) { return ms }
    return matchISO8601DayTime(c)
}

@inline(__always) private func isAsciiDigit(_ ch: Character) -> Bool { ch.isASCII && ch.isNumber }

/// `^(\d+)ms$` (case-insensitive).
private func matchMilliseconds(_ c: [Character]) -> Int? {
    let n = c.count
    guard n >= 3, (c[n - 2] == "m" || c[n - 2] == "M"), (c[n - 1] == "s" || c[n - 1] == "S") else { return nil }
    let digits = c[0..<(n - 2)]
    guard !digits.isEmpty, digits.allSatisfy(isAsciiDigit) else { return nil }
    return Int(String(digits))
}

/// `^(\d*)(\.?)(\d*)s$` (case-insensitive): whole seconds plus up to 3 fractional digits (padded /
/// truncated to millisecond precision), matching xstate's `padEnd(3,'0').slice(0,3)`.
private func matchSeconds(_ c: [Character]) -> Int? {
    let n = c.count
    guard n >= 1, (c[n - 1] == "s" || c[n - 1] == "S") else { return nil }
    var whole = "", frac = ""
    var sawDot = false
    for ch in c[0..<(n - 1)] {
        if ch == "." {
            if sawDot { return nil }
            sawDot = true
        } else if isAsciiDigit(ch) {
            if sawDot { frac.append(ch) } else { whole.append(ch) }
        } else {
            return nil
        }
    }
    let wholeMs = (whole.isEmpty ? 0 : Int(whole) ?? 0) * 1000
    guard sawDot, !frac.isEmpty else { return wholeMs }
    var f = frac
    while f.count < 3 { f.append("0") }
    return wholeMs + (Int(f.prefix(3)) ?? 0)
}

/// `^P(?:nW)?(?:nD)?(?:T(?:nH)?(?:nM)?(?:nS)?)?$` where each `n` is `\d+([.,]\d+)?`, at least one
/// component present. Designators must appear in order (W, D, then T, H, M, S).
private func matchISO8601DayTime(_ c: [Character]) -> Int? {
    var i = 0
    let n = c.count
    guard i < n, c[i] == "P" || c[i] == "p" else { return nil }
    i += 1

    var totalMs = 0.0
    var any = false
    var inTime = false
    var lastRank = -1   // enforce W < D < (T) < H < M < S ordering

    func readNumber() -> Double? {
        var s = ""
        while i < n, isAsciiDigit(c[i]) { s.append(c[i]); i += 1 }
        guard !s.isEmpty else { return nil }                       // \d+ requires leading digit(s)
        if i < n, c[i] == "." || c[i] == "," {
            s.append("."); i += 1
            var frac = 0
            while i < n, isAsciiDigit(c[i]) { s.append(c[i]); i += 1; frac += 1 }
            guard frac > 0 else { return nil }                     // a trailing '.'/',' is invalid
        }
        return Double(s)
    }

    while i < n {
        if c[i] == "T" || c[i] == "t" {
            guard !inTime else { return nil }
            inTime = true; i += 1; continue
        }
        guard let num = readNumber(), i < n else { return nil }
        let d = c[i]; i += 1
        let rank: Int
        let factor: Double
        switch (inTime, d) {
        case (false, "W"), (false, "w"): rank = 0; factor = 7 * 24 * 60 * 60 * 1000
        case (false, "D"), (false, "d"): rank = 1; factor = 24 * 60 * 60 * 1000
        case (true,  "H"), (true,  "h"): rank = 2; factor = 60 * 60 * 1000
        case (true,  "M"), (true,  "m"): rank = 3; factor = 60 * 1000
        case (true,  "S"), (true,  "s"): rank = 4; factor = 1000
        default: return nil
        }
        guard rank > lastRank else { return nil }
        lastRank = rank
        totalMs += num * factor
        any = true
    }

    guard any else { return nil }
    if totalMs >= Double(Int.max) { return Int.max }
    return Int(totalMs.rounded())
}
