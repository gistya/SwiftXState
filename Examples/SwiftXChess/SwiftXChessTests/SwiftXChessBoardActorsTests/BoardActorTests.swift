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
        let actor = createActor(SquareActorMachine())
        await actor.start(context: SquareContext(coord: "e4", occupantId: nil))
        #expect(await actor.matches(path: "empty"))

        await actor.send(.occupy(pieceId: "wPe2"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await actor.matches(path: "occupied"))
        #expect(await actor.context.occupantId == "wPe2")

        await actor.send(.clear)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await actor.matches(path: "empty"))
        #expect(await actor.context.occupantId == nil)
    }

    @Test("piece MOVE_TO and CAPTURED")
    func pieceMoveCaptured() async {
        let actor = createActor(PieceActorMachine())
        await actor.start(context: PieceContext(pieceId: "wPe2", kind: .pawn, color: .white, square: "e2"))
        #expect(await actor.matches(path: "alive"))
        #expect(await actor.context.square == "e2")

        await actor.send(.moveTo(square: "e4"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await actor.context.square == "e4")

        await actor.send(.captured)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await actor.matches(path: "captured"))
        #expect(await actor.context.square == nil)
    }
}
