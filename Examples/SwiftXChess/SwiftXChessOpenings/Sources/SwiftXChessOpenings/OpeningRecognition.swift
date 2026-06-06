import ChessKit
import Foundation

/// Layer 1 — synchronous recognition fold over the transition trace.
public struct OpeningRecognitionState: Sendable {
    public private(set) var fen: FENKey
    public private(set) var fullFEN: String
    public private(set) var board: Board

    public init() throws {
        guard let board = OpeningChessSemantics.makeBoard() else {
            throw OpeningRecognitionError.invalidStartPosition
        }
        self.board = board
        self.fullFEN = board.position.fen
        self.fen = OpeningChessSemantics.normalizeFEN(board.position)
    }

    public mutating func apply(moveSAN: String) throws {
        guard OpeningChessSemantics.apply(san: moveSAN, to: &board) else {
            throw OpeningRecognitionError.illegalMove(moveSAN)
        }
        fullFEN = board.position.fen
        fen = OpeningChessSemantics.normalizeFEN(board.position)
    }

    public func primaryOpening(in dataset: OpeningDataset) -> OpeningLabel? {
        dataset.primaryLabel(at: fen)
    }

    public func alsoTransposed(into dataset: OpeningDataset, primary: OpeningLabel?) -> [OpeningLabel] {
        dataset.transposedLabels(at: fen, excluding: primary)
    }
}

public enum OpeningRecognitionError: Error, Equatable {
    case invalidStartPosition
    case illegalMove(String)
}

public enum OpeningRecognition {
    public static func fold(
        trace: [OpeningTraceStep],
        dataset: OpeningDataset = .bundled
    ) throws -> (state: OpeningRecognitionState, reports: [OpeningLabel?]) {
        var state = try OpeningRecognitionState()
        var primaries: [OpeningLabel?] = [dataset.primaryLabel(at: state.fen)]
        for step in trace {
            try state.apply(moveSAN: step.moveSAN)
            primaries.append(dataset.primaryLabel(at: state.fen))
        }
        return (state, primaries)
    }
}