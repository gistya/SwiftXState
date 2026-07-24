import FridayTheCodable
import SwiftXState
#if canImport(os)
import os
#endif

/// Something that logs inspection wire messages, composed over a ``LogWriteable`` sink and decoupled
/// from any concrete output. Swap the `Writer` (console, file, pipe, network stream…) without the
/// logger — or the inspector — knowing which one it is.
public protocol InspectLoggable: Sendable {
    associatedtype Writer: LogWriteable
    var writer: Writer { get }
}

public extension InspectLoggable {
    /// Encode `message` as a one-line JSONL record and write it through the composed sink.
    func log(_ message: InspectWireMessage) async throws {
        try await writer.write(message.jsonlRecord())
    }

    /// Tear down the underlying sink.
    func close() async { await writer.close() }
}

public extension InspectWireMessage {
    /// A `{ type, payload, timestamp }` JSON object plus a trailing newline — the JSONL record every
    /// ``LogWriteable`` sink appends. Foundation-free (FridayTheCodable + the core wall clock).
    func jsonlRecord() throws -> [UInt8] {
        struct Record: Encodable {
            let type: String
            let payload: String
            let timestamp: Double
        }
        let payloadText = String(decoding: payload, as: UTF8.self)
        let timestamp = Double(wallClockNanosecondsSince1970()) / 1_000_000_000
        var bytes = try FridayJSONEncoder().encode(Record(type: type, payload: payloadText, timestamp: timestamp))
        bytes.append(0x0A)
        return bytes
    }
}

// MARK: - Default (Foundation-free) sinks

/// The default sink: `os.Logger` on Apple, `print` everywhere else. Foundation-free on every target.
public struct ConsoleLogWriter: LogWriteable {
    #if canImport(os)
    private let logger: Logger
    public init(subsystem: String = "SwiftXState", category: String = "inspect") {
        logger = Logger(subsystem: subsystem, category: category)
    }
    #else
    public init(subsystem: String = "SwiftXState", category: String = "inspect") {}
    #endif

    public func write(_ bytes: [UInt8]) async throws {
        let text = String(decoding: bytes, as: UTF8.self)
        #if canImport(os)
        logger.log("\(text, privacy: .public)")
        #else
        print(text, terminator: "")   // the record already carries its newline
        #endif
    }

    public func close() async {}
}

/// A ready-made logger over ``ConsoleLogWriter`` — the default when no sink is injected.
public struct ConsoleInspectLogger: InspectLoggable {
    public let writer: ConsoleLogWriter
    public init(writer: ConsoleLogWriter = ConsoleLogWriter()) { self.writer = writer }
}
