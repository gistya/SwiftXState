import Foundation

/// Semantic FEN key (placement, side, castling, en-passant — no move clocks).
public typealias FENKey = String

public struct OpeningTreeContext: Sendable, Equatable, Codable {
    public var nodeId: String
    public var ply: Int

    public static func initial(rootId: String) -> OpeningTreeContext {
        OpeningTreeContext(nodeId: rootId, ply: 0)
    }
}

public struct OpeningLabel: Sendable, Equatable, Codable, Hashable, Comparable {
    public let eco: String
    public let name: String
    public let variation: String
    public let depth: Int

    public var displayPath: String {
        variation.isEmpty ? name : "\(name) → \(variation)"
    }

    public static func < (lhs: OpeningLabel, rhs: OpeningLabel) -> Bool {
        if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
        if lhs.eco != rhs.eco { return lhs.eco < rhs.eco }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.variation < rhs.variation
    }
}

public struct TranspositionCandidate: Sendable, Equatable, Codable, Comparable {
    public let move: String
    public let eco: String
    public let name: String
    public let variation: String

    public var label: OpeningLabel {
        OpeningLabel(eco: eco, name: name, variation: variation, depth: 0)
    }

    public static func < (lhs: TranspositionCandidate, rhs: TranspositionCandidate) -> Bool {
        let left = OpeningLabel(eco: lhs.eco, name: lhs.name, variation: lhs.variation, depth: 0)
        let right = OpeningLabel(eco: rhs.eco, name: rhs.name, variation: rhs.variation, depth: 0)
        if left != right { return left < right }
        return lhs.move < rhs.move
    }
}

public struct PlyReport: Sendable, Equatable, Codable {
    public let ply: Int
    public let move: String
    public let currentPosition: String
    public let primaryOpening: OpeningLabel?
    public let alsoTransposedInto: [OpeningLabel]
    public let oneMoveAway: [TranspositionCandidate]
}

/// Pure transition trace step emitted by the base move-tree (`from`, SAN, `to`).
public struct OpeningTraceStep: Sendable, Equatable {
    public let fromNodeId: String
    public let moveSAN: String
    public let toNodeId: String
    public let ply: Int
}