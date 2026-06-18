import Foundation

extension ReplaySession {
    public func encodeJSON() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decodeJSON(_ data: Data) throws -> ReplaySession {
        try JSONDecoder().decode(ReplaySession.self, from: data)
    }
}

extension ReplayableEvent {
    private enum Discriminator: String, Codable {
        case simple
        case system
        case done
        case error
        case snapshotSync
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case type
        case payload
        case actorId
        case outputDescription
        case message
        case value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .simple(type, payload):
            try container.encode(Discriminator.simple, forKey: .kind)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(payload, forKey: .payload)
        case let .system(event):
            try container.encode(Discriminator.system, forKey: .kind)
            try container.encode(event, forKey: .type)
        case let .done(actorId, outputDescription):
            try container.encode(Discriminator.done, forKey: .kind)
            try container.encode(actorId, forKey: .actorId)
            try container.encodeIfPresent(outputDescription, forKey: .outputDescription)
        case let .error(actorId, message):
            try container.encode(Discriminator.error, forKey: .kind)
            try container.encode(actorId, forKey: .actorId)
            try container.encode(message, forKey: .message)
        case let .snapshotSync(actorId, value):
            try container.encode(Discriminator.snapshotSync, forKey: .kind)
            try container.encode(actorId, forKey: .actorId)
            try container.encodeIfPresent(value, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Discriminator.self, forKey: .kind)
        switch kind {
        case .simple:
            self = .simple(
                type: try container.decode(String.self, forKey: .type),
                payload: try container.decodeIfPresent(JSONValue.self, forKey: .payload)
            )
        case .system:
            self = .system(try container.decode(SystemEvent.self, forKey: .type))
        case .done:
            self = .done(
                actorId: try container.decode(String.self, forKey: .actorId),
                outputDescription: try container.decodeIfPresent(String.self, forKey: .outputDescription)
            )
        case .error:
            self = .error(
                actorId: try container.decode(String.self, forKey: .actorId),
                message: try container.decode(String.self, forKey: .message)
            )
        case .snapshotSync:
            self = .snapshotSync(
                actorId: try container.decode(String.self, forKey: .actorId),
                value: try container.decodeIfPresent(String.self, forKey: .value)
            )
        }
    }
}