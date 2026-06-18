import Testing
@testable import SwiftXState
@testable import SwiftXChess

@Suite("Board reactor primitives")
struct BoardReactorTests {
    @Test("square ids use coord suffix")
    func squareIds() {
        #expect(BoardReactorIds.square("e4") == "square.e4")
        #expect(BoardReactorIds.square(Square(row: 1, col: 4)) == "square.e2")
        #expect(BoardReactorIds.coord(Square(row: 4, col: 4)) == "e5")
    }

    @Test("piece ids use stable home notation")
    func pieceIds() {
        let id = PieceInstanceId.make(color: .white, kind: .pawn, home: Square(row: 1, col: 4))
        #expect(id.token == "wPe2")
        #expect(BoardReactorIds.piece(id: id.token) == "piece.wPe2")
    }

    @Test("standard layout seeds 64 squares and 32 pieces")
    func standardLayout() {
        let seed = BoardLayoutSeed.standard()
        #expect(seed.squares.count == 64)
        #expect(seed.pieces.count == 32)
        #expect(seed.squares.first(where: { $0.coord == "e2" })?.occupantId == "wPe2")
        #expect(seed.allChildIds.count == 96)
    }

    @Test("square OCCUPY and CLEAR")
    func squareOccupyClear() async {
        let reactor = createReactor(SquareReactorMachine.machine)
            .start(context: SquareContext(coord: "e4", occupantId: nil))

        #expect(reactor.snapshot.matches("empty"))

        reactor.send(Event("OCCUPY.wPe2"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(reactor.snapshot.matches("occupied"))
        #expect(reactor.snapshot.context.occupantId == "wPe2")

        reactor.send(Event("CLEAR"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(reactor.snapshot.matches("empty"))
        #expect(reactor.snapshot.context.occupantId == nil)
    }

    @Test("piece MOVE_TO and CAPTURED")
    func pieceMoveCaptured() async {
        let reactor = createReactor(PieceReactorMachine.machine)
            .start(context: PieceContext(pieceId: "wPe2", kind: .pawn, color: .white, square: "e2"))

        #expect(reactor.snapshot.matches("alive"))
        #expect(reactor.snapshot.context.square == "e2")

        reactor.send(Event("MOVE_TO.e4"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(reactor.snapshot.context.square == "e4")

        reactor.send(Event("CAPTURED"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(reactor.snapshot.matches("captured"))
        #expect(reactor.snapshot.context.square == nil)
    }
}
