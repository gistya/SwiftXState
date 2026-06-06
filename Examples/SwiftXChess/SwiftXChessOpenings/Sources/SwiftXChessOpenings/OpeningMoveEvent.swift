import Foundation
import SwiftXState

public struct OpeningMoveEvent: Eventable, Equatable, Sendable {
    public let san: String

    public init(san: String) {
        self.san = san
    }

    public var type: String { "SAN.\(san)" }

    public static func from(event: any Eventable) -> OpeningMoveEvent? {
        let type = event.type
        guard type.hasPrefix("SAN.") else { return nil }
        return OpeningMoveEvent(san: String(type.dropFirst(4)))
    }
}