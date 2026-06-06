import Foundation
import Testing
@testable import SwiftXChessOpenings

@Suite("Opening recognition Layer 1", .serialized)
struct OpeningRecognitionTests {
    @Test("e4 is recognized from starting position")
    func e4Opening() async throws {
        let session = try OpeningTreeSession()
        await session.sendAndWait(san: "e4")
        let reports = await session.reports()
        #expect(reports.count == 1)
        #expect(reports[0].move == "e4")
        #expect(reports[0].primaryOpening != nil)
    }

    @Test("Sicilian line reaches Najdorf territory by ply 5")
    func sicilianNajdorf() async throws {
        let moves = ["e4", "c5", "Nf3", "d6", "d4", "cxd4", "Nxd4", "Nf6", "Nc3", "a6"]
        let session = try OpeningTreeSession()
        for move in moves {
            await session.sendAndWait(san: move)
        }
        let reports = await session.reports()
        #expect(reports.count == moves.count)
        let last = reports.last
        #expect(last?.primaryOpening?.name.contains("Sicilian") == true)
        let labels = last.map { OpeningDataset.bundled.labels(at: $0.currentPosition) } ?? []
        let hasNajdorf = labels.contains { $0.variation.contains("Najdorf") || $0.displayPath.contains("Najdorf") }
        #expect(hasNajdorf)
    }

    @Test("trace fold is deterministic across replays")
    func deterministicTraceFold() async throws {
        let moves = ["e4", "c5", "Nf3"]
        func run() async throws -> [PlyReport] {
            let session = try OpeningTreeSession()
            for move in moves { await session.sendAndWait(san: move) }
            return await session.reports()
        }
        let first = try await run()
        let second = try await run()
        #expect(first == second)
    }

    @Test("processTrace matches live inspect reports")
    func traceReplayMatchesLive() async throws {
        let moves = ["d4", "Nf6", "c4", "e6"]
        let session = try OpeningTreeSession()
        for move in moves { await session.sendAndWait(san: move) }
        let live = await session.reports()
        let replayed = try await session.processTrace()
        #expect(live == replayed)
    }
}