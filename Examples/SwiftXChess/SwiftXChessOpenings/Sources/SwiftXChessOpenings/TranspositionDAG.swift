import Foundation

public struct TranspositionEdge: Sendable, Equatable, Codable, Hashable {
    public let fromFEN: FENKey
    public let moveSAN: String
    public let toFEN: FENKey
}

/// Queryable transposition graph built as a side effect of adjacency probes.
public struct TranspositionDAG: Sendable, Equatable {
    public private(set) var edges: Set<TranspositionEdge> = []
    public private(set) var knownFENs: Set<FENKey> = []

    public init(knownFENs: Set<FENKey> = []) {
        self.knownFENs = knownFENs
    }

    public mutating func record(from: FENKey, move: String, to: FENKey) {
        edges.insert(TranspositionEdge(fromFEN: from, moveSAN: move, toFEN: to))
        noteKnown(fen: from)
        noteKnown(fen: to)
    }

    public mutating func noteKnown(fen: FENKey) {
        knownFENs.insert(fen)
    }

    public func outgoing(from fen: FENKey) -> [TranspositionEdge] {
        edges.filter { $0.fromFEN == fen }.sorted {
            if $0.moveSAN != $1.moveSAN { return $0.moveSAN < $1.moveSAN }
            return $0.toFEN < $1.toFEN
        }
    }
}