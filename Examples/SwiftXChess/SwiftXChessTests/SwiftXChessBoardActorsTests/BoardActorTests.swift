import Testing
@testable import SwiftXState
@testable import SwiftXChess

@Suite("Board actor primitives")
struct BoardActorTests {
    @Test("square ids use coord suffix")
    func squareIds() {
        #expect(BoardActorIds.square("e4") == "square.e4")
        #expect(BoardActorIds.square(Square(row: 1, col: 4)) == "square.e2")
        #expect(BoardActorIds.coord(Square(row: 4, col: 4)) == "e5")
    }

    @Test("piece ids use stable home notation")
    func pieceIds() {
        let id = PieceInstanceId.make(color: .white, kind: .pawn, home: Square(row: 1, col: 4))
        #expect(id.token == "wPe2")
        #expect(BoardActorIds.piece(id: id.token) == "piece.wPe2")
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
        let actor = createActor(SquareActorMachine.machine)
            .start(context: SquareContext(coord: "e4", occupantId: nil))

        #expect(actor.snapshot.matches("empty"))

        actor.send(Event("OCCUPY.wPe2"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(actor.snapshot.matches("occupied"))
        #expect(actor.snapshot.context.occupantId == "wPe2")

        actor.send(Event("CLEAR"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(actor.snapshot.matches("empty"))
        #expect(actor.snapshot.context.occupantId == nil)
    }

    @Test("piece MOVE_TO and CAPTURED")
    func pieceMoveCaptured() async {
        let actor = createActor(PieceActorMachine.machine)
            .start(context: PieceContext(pieceId: "wPe2", kind: .pawn, color: .white, square: "e2"))

        #expect(actor.snapshot.matches("alive"))
        #expect(actor.snapshot.context.square == "e2")

        actor.send(Event("MOVE_TO.e4"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(actor.snapshot.context.square == "e4")

        actor.send(Event("CAPTURED"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(actor.snapshot.matches("captured"))
        #expect(actor.snapshot.context.square == nil)
    }
}
