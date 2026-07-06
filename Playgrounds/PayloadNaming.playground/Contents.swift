import Foundation

// ════════════════════════════════════════════════════════════════════════════
//  Why multi-value payload events showed up as "*", and how the variadic
//  `Map<(repeat each Payload), EventID>` overload fixes it.
//
//  Self-contained: paste into an Xcode Playground, or run `swift PayloadNaming.swift`.
//  Mirrors the exact pieces of the SwiftXState DSL involved — nothing imported.
// ════════════════════════════════════════════════════════════════════════════

// 1️⃣  Blankable — a type that can hand back a throwaway sample of itself.
protocol Blankable { static var _blank: Self { get } }
extension String:  Blankable { static var _blank: String  { "" } }
extension Int:     Blankable { static var _blank: Int     { 0 } }
extension Double:  Blankable { static var _blank: Double  { 0 } }
extension Bool:    Blankable { static var _blank: Bool    { false } }
extension Optional: Blankable { static var _blank: Wrapped? { nil } }

// 2️⃣  Events. `.name` is recovered by reflection — exactly how SwiftXState derives the case label.
protocol EventIdentifying {}
extension EventIdentifying {
    var name: String { Mirror(reflecting: self).children.first?.label ?? String(describing: self) }
}

enum SoundtrackEvent: EventIdentifying {
    case launch                                                          // 0 values
    case setVolume(Double)                                              // 1 value
    case audioFailed(String, generation: Int?)                         // 2 values ← was "*"
    case playbackPrepared(title: String?, generation: Int, started: Bool)  // 3 values ← was "*"
}

// 3️⃣  The dot-syntax `Map` workaround: lets you write `.audioFailed` where a payload case is wanted.
struct Map<In, Out> { let transform: @Sendable (In) -> Out }
extension Map where In == Double, Out == SoundtrackEvent {
    static var setVolume: Map { .init(transform: SoundtrackEvent.setVolume) }
}
extension Map where In == (String, Int?), Out == SoundtrackEvent {
    static var audioFailed: Map { .init(transform: { SoundtrackEvent.audioFailed($0.0, generation: $0.1) }) }
}
extension Map where In == (String?, Int, Bool), Out == SoundtrackEvent {
    static var playbackPrepared: Map { .init(transform: { SoundtrackEvent.playbackPrepared(title: $0.0, generation: $0.1, started: $0.2) }) }
}

// A transition records the descriptor it registers under: the event's name, or "*" when unknown.
struct Transition { let descriptor: String }

// ── BEFORE ── only the scalar `Map` overloads (what you had). ────────────────
enum Before {
    static func on(_ e: SoundtrackEvent) -> Transition { .init(descriptor: e.name) }          // 0-value: value form
    static func on<P>(_ map: Map<P, SoundtrackEvent>) -> Transition { .init(descriptor: "*") } // wildcard fallback
    static func on<P: Blankable>(_ map: Map<P, SoundtrackEvent>) -> Transition {               // names 1-value only
        .init(descriptor: map.transform(P._blank).name)
    }
}

// ── AFTER ── add the variadic pack overload (same `Map` type). ───────────────
enum After {
    static func on(_ e: SoundtrackEvent) -> Transition { .init(descriptor: e.name) }
    static func on<P>(_ map: Map<P, SoundtrackEvent>) -> Transition { .init(descriptor: "*") }
    static func on<P: Blankable>(_ map: Map<P, SoundtrackEvent>) -> Transition {
        .init(descriptor: map.transform(P._blank).name)
    }
    static func on<each P: Blankable>(_ map: Map<(repeat each P), SoundtrackEvent>) -> Transition {
        let blanks: (repeat each P) = (repeat (each P)._blank)   // ← the blank tuple, built inline
        return .init(descriptor: map.transform(blanks).name)
    }
}

// ── Demo ─────────────────────────────────────────────────────────────────────
func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
func row(_ label: String, _ b: Transition, _ a: Transition) {
    let mark = a.descriptor == "*" ? "❌ wildcard" : (a.descriptor == label ? "✅ named" : "⚠️ \(a.descriptor)")
    print("  \(pad(label, 18))  before: \(pad(b.descriptor, 10))  after: \(pad(a.descriptor, 18))  \(mark)")
}

print("\n  event               before (scalar only)     after (+ pack overload)")
print("  " + String(repeating: "─", count: 68))
row("launch",           Before.on(.launch),           After.on(.launch))
row("setVolume",        Before.on(.setVolume),        After.on(.setVolume))
row("audioFailed",      Before.on(.audioFailed),      After.on(.audioFailed))
row("playbackPrepared", Before.on(.playbackPrepared), After.on(.playbackPrepared))
print("")
