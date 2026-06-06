import Foundation

/// Appends JSONL inspect messages to a file — zero network, useful on device and in CI.
public final class FileInspectTransport: InspectTransport, Sendable {
    public let policy: ConnectivityPolicy
    private let writer: FileInspectWriter

    public init(fileURL: URL, policy: ConnectivityPolicy = .localhostOnly()) {
        self.policy = policy
        self.writer = FileInspectWriter(fileURL: fileURL)
    }

    public func connect(to endpoint: InspectEndpoint) async throws -> any InspectSession {
        _ = try EndpointValidator(policy: policy).validate(endpoint)
        return FileInspectSession(writer: writer)
    }
}

actor FileInspectWriter {
    private let fileURL: URL
    private var closed = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func append(_ message: InspectWireMessage) throws {
        guard !closed else { throw InspectTransportError.notConnected }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var record: [String: String] = [
            "type": message.type,
            "payload": String(data: message.payload, encoding: .utf8) ?? "",
        ]
        record["timestamp"] = String(Date().timeIntervalSince1970)
        let line = try JSONSerialization.data(withJSONObject: record)
        handle.write(line)
        handle.write(Data([0x0A]))
    }

    func close() {
        closed = true
    }
}

actor FileInspectSession: InspectSession {
    private let writer: FileInspectWriter
    private var closed = false

    init(writer: FileInspectWriter) {
        self.writer = writer
    }

    func publish(_ message: InspectWireMessage) async throws {
        guard !closed else { throw InspectTransportError.notConnected }
        try await writer.append(message)
    }

    func close() async {
        closed = true
        await writer.close()
    }
}