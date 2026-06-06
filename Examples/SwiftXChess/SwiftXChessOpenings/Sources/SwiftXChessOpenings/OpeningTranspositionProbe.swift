import ChessKit
import Foundation

/// Layer 2 — concurrent one-move transposition frontier probes.
public enum OpeningTranspositionProbe {
    public struct ProbeInput: Sendable {
        public let board: Board
        public let dataset: OpeningDataset
        public var dag: TranspositionDAG

        public init(board: Board, dataset: OpeningDataset = .bundled, dag: TranspositionDAG) {
            self.board = board
            self.dataset = dataset
            self.dag = dag
        }
    }

    public static func probeOneMoveAway(
        input: ProbeInput
    ) async -> (candidates: [TranspositionCandidate], dag: TranspositionDAG) {
        let legalMoves = OpeningChessSemantics.legalSANMoves(on: input.board)
        let fromFEN = OpeningChessSemantics.normalizeFEN(input.board.position)
        var dag = input.dag

        let hits = await withTaskGroup(of: [TranspositionCandidate].self, returning: [TranspositionCandidate].self) { group in
            for san in legalMoves {
                group.addTask {
                    await Self.probeMove(
                        san: san,
                        fromFEN: fromFEN,
                        board: input.board,
                        dataset: input.dataset
                    )
                }
            }

            var merged: [TranspositionCandidate] = []
            for await batch in group {
                merged.append(contentsOf: batch)
            }
            return merged
        }

        for san in legalMoves {
            guard var trial = duplicateBoard(input.board),
                  OpeningChessSemantics.apply(san: san, to: &trial) else {
                continue
            }
            let toFEN = OpeningChessSemantics.normalizeFEN(trial.position)
            dag.record(from: fromFEN, move: san, to: toFEN)
            if input.dataset.equivalence[toFEN] != nil {
                dag.noteKnown(fen: toFEN)
            }
        }

        var unique: [TranspositionCandidate] = []
        var seen: Set<String> = []
        for candidate in hits.sorted() {
            let key = "\(candidate.move)|\(candidate.eco)|\(candidate.name)|\(candidate.variation)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(candidate)
        }
        return (unique, dag)
    }

    private static func probeMove(
        san: String,
        fromFEN: FENKey,
        board: Board,
        dataset: OpeningDataset
    ) async -> [TranspositionCandidate] {
        guard var trial = duplicateBoard(board),
              OpeningChessSemantics.apply(san: san, to: &trial) else {
            return []
        }
        let toFEN = OpeningChessSemantics.normalizeFEN(trial.position)
        guard let labels = dataset.fenLabels[toFEN], !labels.isEmpty else {
            return []
        }
        _ = fromFEN
        return labels
            .map(\.label)
            .sorted()
            .map { label in
                TranspositionCandidate(
                    move: san,
                    eco: label.eco,
                    name: label.name,
                    variation: label.variation
                )
            }
    }

    private static func duplicateBoard(_ board: Board) -> Board? {
        OpeningChessSemantics.makeBoard(fen: board.position.fen)
    }
}