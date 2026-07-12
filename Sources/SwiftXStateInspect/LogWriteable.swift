/// A raw outbound sink — **anything that sends bytes to the outside world**: a file, a
/// console / terminal / pipe, a network stream. Concrete writers live wherever their platform
/// dependency does (e.g. the file writer ships in `SwiftXStateInspectLog`, which links Foundation);
/// the inspector depends only on this port, never on a concrete implementation.
///
/// A writer receives already-framed records — the bytes passed to ``write(_:)`` are written verbatim
/// (a JSONL record already includes its trailing newline).
public protocol LogWriteable: Sendable {
    /// Write one framed record's bytes to the sink.
    func write(_ bytes: [UInt8]) async throws
    /// Flush and release the sink. Idempotent.
    func close() async
}
