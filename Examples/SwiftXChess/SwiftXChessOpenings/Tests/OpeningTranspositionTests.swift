import Foundation
import Testing
@testable import SwiftXChessOpenings

@Suite("Opening transposition Layer 2", .serialized)
struct OpeningTranspositionTests {
    @Test("one-move-away probes return sorted candidates")
    func sortedCandidates() async throws {
        let session = try OpeningTreeSession()
        await session.sendAndWait(san: "e4")
        let reports = await session.reports()
        guard let first = reports.first else {
            Issue.record("Expected ply report")
            return
        }
        #expect(first.oneMoveAway == first.oneMoveAway.sorted())
    }

    @Test("transposition DAG accumulates edges")
    func dagEdges() async throws {
        let session = try OpeningTreeSession()
        await session.sendAndWait(san: "e4")
        await session.sendAndWait(san: "e5")
        let dag = await session.transpositionDAG()
        #expect(!dag.edges.isEmpty)
    }

    @Test("20 replays produce identical reports")
    func determinismTwentyRuns() async throws {
        let moves = ["e4", "e5", "Nf3", "Nc6", "Bb5"]
        var baseline: [PlyReport]?
        for _ in 0..<20 {
            let session = try OpeningTreeSession()
            for move in moves { await session.sendAndWait(san: move) }
            let reports = await session.reports()
            if let baseline {
                #expect(reports == baseline)
            } else {
                baseline = reports
            }
        }
        #expect(baseline?.count == moves.count)
    }

    @Test("10 full moves produce identical reports across 20 replays")
    func determinismTenPlies() async throws {
        let moves = ["e4", "c5", "Nf3", "d6", "d4", "cxd4", "Nxd4", "Nf6", "Nc3", "a6"]
        var baseline: [PlyReport]?
        for _ in 0..<20 {
            let session = try OpeningTreeSession()
            for move in moves { await session.sendAndWait(san: move) }
            let reports = await session.reports()
            if let baseline {
                #expect(reports == baseline)
            } else {
                baseline = reports
            }
        }
        #expect(baseline?.count == 10)
        let labels = baseline?.last.map { OpeningDataset.bundled.labels(at: $0.currentPosition) } ?? []
        let hasNajdorf = labels.contains { $0.variation.contains("Najdorf") || $0.displayPath.contains("Najdorf") }
        #expect(hasNajdorf)
    }
}