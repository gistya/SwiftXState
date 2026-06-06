import Foundation

public struct OpeningDataset: Sendable {
    public let version: Int
    public let maxPlies: Int
    public let rootId: String
    public let nodes: [String: [String: String]]
    public let fenLabels: [FENKey: [OpeningLabelRecord]]
    public let equivalence: [FENKey: Set<String>]
    public let nodePlies: [String: Int]
    public let stats: Stats

    public struct Stats: Sendable, Equatable, Codable {
        public let tsvRows: Int
        public let nodeCount: Int
        public let fenCount: Int
    }

    public struct OpeningLabelRecord: Sendable, Equatable, Codable {
        public let eco: String
        public let name: String
        public let variation: String
        public let depth: Int
        public let stateId: String

        public var label: OpeningLabel {
            OpeningLabel(eco: eco, name: name, variation: variation, depth: depth)
        }
    }

    public static let bundled: OpeningDataset = {
        do {
            return try loadBundled()
        } catch {
            fatalError("Failed to load openings-5move.json: \(error)")
        }
    }()

    public static func loadBundled() throws -> OpeningDataset {
        guard let url = Bundle.module.url(
            forResource: "openings-5move",
            withExtension: "json"
        ) else {
            throw OpeningDatasetError.missingResource
        }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> OpeningDataset {
        let raw = try JSONDecoder().decode(RawDataset.self, from: data)
        let equivalence = raw.equivalence.mapValues { Set($0) }
        let nodePlies = computePlies(rootId: raw.rootId, nodes: raw.nodes)
        return OpeningDataset(
            version: raw.version,
            maxPlies: raw.maxPlies,
            rootId: raw.rootId,
            nodes: raw.nodes,
            fenLabels: raw.fenLabels,
            equivalence: equivalence,
            nodePlies: nodePlies,
            stats: raw.stats
        )
    }

    public func ply(for nodeId: String) -> Int {
        nodePlies[nodeId] ?? 0
    }

    public func labels(at fen: FENKey) -> [OpeningLabel] {
        (fenLabels[fen] ?? []).map(\.label)
    }

    public func primaryLabel(at fen: FENKey) -> OpeningLabel? {
        labels(at: fen).sorted().first
    }

    public func transposedLabels(at fen: FENKey, excluding primary: OpeningLabel?) -> [OpeningLabel] {
        let all = labels(at: fen).sorted()
        guard let primary else { return Array(all.dropFirst()) }
        return all.filter { $0 != primary }
    }

    private static func computePlies(
        rootId: String,
        nodes: [String: [String: String]]
    ) -> [String: Int] {
        var plies = [rootId: 0]
        var queue = [rootId]
        while let current = queue.first {
            queue.removeFirst()
            let depth = plies[current] ?? 0
            for target in nodes[current].map({ Array($0.values) }) ?? [] {
                if plies[target] == nil {
                    plies[target] = depth + 1
                    queue.append(target)
                }
            }
        }
        return plies
    }
}

public enum OpeningDatasetError: Error {
    case missingResource
}

private struct RawDataset: Decodable {
    let version: Int
    let maxPlies: Int
    let rootId: String
    let nodes: [String: [String: String]]
    let fenLabels: [FENKey: [OpeningDataset.OpeningLabelRecord]]
    let equivalence: [FENKey: [String]]
    let stats: OpeningDataset.Stats
}