import Foundation
import SwiftXStateInspect

/// A ``LogWriteable`` that appends framed records to a file (JSONL). This is the **only**
/// Foundation-dependent output sink — import `SwiftXStateInspectLog` when you want file logging;
/// the inspector core (`SwiftXStateInspect`) stays Foundation-free and defaults to a console sink.
public actor FileLogWriter: LogWriteable {
    private let fileURL: URL
    private var closed = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard !closed else { return }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(Data(bytes))   // the record already carries its trailing newline
    }

    public func close() async { closed = true }
}

/// A logger that appends inspection records to a file. The file-backed replacement for the old
/// `FileInspectTransport`: `FileInspectLogger(fileURL:).log(message)`.
public struct FileInspectLogger: InspectLoggable {
    public let writer: FileLogWriter
    public init(fileURL: URL) { writer = FileLogWriter(fileURL: fileURL) }
}
