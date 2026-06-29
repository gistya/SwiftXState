/// Lightweight snapshot for replay history (avoids copying rules/speed/etc on every generation).
/// This is critical for keeping autoplay (Play mode) as fast as manual Step spam.
public struct GridSnapshot: Sendable, Equatable {
    public let generation: Int
    public let cells: [Bool]
}
