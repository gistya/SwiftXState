/// A type that can hand out a throwaway placeholder instance of itself — the same `_blank` convention
/// `BasicIdentifying` / `PropertyInitializable` already use, extracted so payload *component* types can
/// opt into it too.
///
/// It exists for one job: a payload-carrying event transition (`XTransition(on: SoundtrackEvent.setVolume,
/// …)`) hands the DSL only the case *constructor* `(Double) -> SoundtrackEvent`, never a value — so the
/// case name isn't recoverable. Given `Double: Blankable`, the DSL constructs a sample
/// (`SoundtrackEvent.setVolume(Double._blank)`) purely to read `"setVolume"` off it via `Mirror` (the
/// same mechanism as `BasicIdentifying.name`), then discards it. Because the sample is thrown away, the
/// placeholder *value* never matters — only that one can be produced. That safety (Mirror over a real,
/// valid value) is what makes this categorically unlike raw enum-metadata reflection.
///
/// A payload struct that already conforms to `PropertyInitializable` gets `Blankable` for free with an
/// empty `extension MyType: Blankable {}` (its `_blank` satisfies the requirement).
public protocol Blankable {
    static var _blank: Self { get }
}

extension Int: Blankable { public static var _blank: Int { 0 } }
extension Int8: Blankable { public static var _blank: Int8 { 0 } }
extension Int16: Blankable { public static var _blank: Int16 { 0 } }
extension Int32: Blankable { public static var _blank: Int32 { 0 } }
extension Int64: Blankable { public static var _blank: Int64 { 0 } }
extension UInt: Blankable { public static var _blank: UInt { 0 } }
extension UInt8: Blankable { public static var _blank: UInt8 { 0 } }
extension UInt32: Blankable { public static var _blank: UInt32 { 0 } }
extension UInt64: Blankable { public static var _blank: UInt64 { 0 } }
extension Double: Blankable { public static var _blank: Double { 0 } }
extension Float: Blankable { public static var _blank: Float { 0 } }
extension Bool: Blankable { public static var _blank: Bool { false } }
extension String: Blankable {}   // already has `_blank` via its PropertyInitializable conformance
extension Character: Blankable { public static var _blank: Character { " " } }
extension Optional: Blankable { public static var _blank: Wrapped? { nil } }
extension Array: Blankable { public static var _blank: [Element] { [] } }
extension Dictionary: Blankable { public static var _blank: [Key: Value] { [:] } }
extension Set: Blankable { public static var _blank: Set<Element> { [] } }
