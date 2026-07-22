import SwiftXState

// Engine dispatch: parse a JSON request, route on its "op", return a JSON reply.
// Every reply is `{ "ok": true, "result": ... }` or `{ "ok": false, "error": "..." }`.
//
// JSON in / JSON out is handled entirely by SwiftXState core's own `JSONValue`
// (`.parse` / `.serialized()`) — no Foundation, no Codable, Embedded-safe.
enum Engine {
    static let name = "swiftxstate-embedded-wasm"
    static let version = "0.1.0"

    // Session singleton: the wasm instance persists across queries, so each machine's
    // live snapshot is held here (keyed by machine id) until the page reloads. State
    // lives here (a `static`), never as a `main.swift` global, so it initialises
    // lazily under the reactor model rather than in a `main()` that never runs.
    nonisolated(unsafe) static var sessions: [String: any MachineSession] = [:]

    /// Handle one request: UTF-8 JSON bytes in, UTF-8 JSON bytes out.
    static func handle(requestBytes: [UInt8]) -> [UInt8] {
        let text = String(decoding: requestBytes, as: UTF8.self)
        guard let request = JSONValue.parse(text) else {
            return serialize(err("request is not valid JSON"))
        }
        guard case let .object(fields) = request,
              case let .string(op)? = fields["op"] else {
            return serialize(err("request is missing an 'op' string"))
        }

        let response: JSONValue
        switch op {
        case "catalog":
            response = ok(.object([
                "engine": .string(name),
                "version": .string(version),
                "machines": Registry.catalogJSON(),
            ]))
        case "reset":
            response = mutate(fields, reset: true)
        case "send":
            response = mutate(fields, reset: false)
        case "snapshot":
            response = view(fields)
        default:
            response = err("unknown op: \(op)")
        }
        return serialize(response)
    }

    // MARK: - Ops

    private static func session(for id: String) -> (any MachineSession)? {
        if let existing = sessions[id] { return existing }
        guard let created = Registry.makeSession(id) else { return nil }
        sessions[id] = created
        return created
    }

    private static func mutate(_ fields: [String: JSONValue], reset: Bool) -> JSONValue {
        guard case let .string(id)? = fields["machine"] else {
            return err("missing 'machine'")
        }
        guard let s = session(for: id) else { return err("unknown machine: \(id)") }
        if reset {
            s.reset()
        } else {
            guard case let .string(event)? = fields["event"] else {
                return err("missing 'event'")
            }
            s.send(event)
        }
        return ok(snapshotJSON(id: id, session: s))
    }

    private static func view(_ fields: [String: JSONValue]) -> JSONValue {
        guard case let .string(id)? = fields["machine"] else {
            return err("missing 'machine'")
        }
        guard let s = session(for: id) else { return err("unknown machine: \(id)") }
        return ok(snapshotJSON(id: id, session: s))
    }

    private static func snapshotJSON(id: String, session: any MachineSession) -> JSONValue {
        let events: [JSONValue] = session.eventNames.map { name in
            .object([
                "name": .string(name),
                "enabled": .bool(session.canSend(name)),
            ])
        }
        return .object([
            "machine": .string(id),
            "state": .string(session.stateName),
            "context": session.contextJSON,
            "done": .bool(session.isDone),
            "events": .array(events),
        ])
    }

    // MARK: - Reply helpers

    static func ok(_ result: JSONValue) -> JSONValue {
        .object(["ok": .bool(true), "result": result])
    }

    static func err(_ message: String) -> JSONValue {
        .object(["ok": .bool(false), "error": .string(message)])
    }

    static func serialize(_ value: JSONValue) -> [UInt8] {
        Array(value.serialized().utf8)
    }
}
