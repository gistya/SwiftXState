import Testing
@testable import SwiftXChessOpenings

@Suite("FEN key diagnostics")
struct FENKeyDiagnosticsTests {
    @Test("e4 FEN matches dataset key")
    func e4FENKey() throws {
        var state = try OpeningRecognitionState()
        try state.apply(moveSAN: "e4")
        let expected = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -"
        #expect(state.fen == expected)
        #expect(OpeningDataset.bundled.fenLabels[state.fen] != nil)
    }
}