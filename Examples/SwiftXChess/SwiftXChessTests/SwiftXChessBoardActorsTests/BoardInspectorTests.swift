import Testing
@testable import SwiftXState
import SwiftXChessOpenings
@testable import SwiftXChess

@Suite("Board inspector facade")
struct BoardInspectorTests {
    @Test("occupancy board is a 64-square parallel machine")
    func exportsOccupancyStructure() throws {
        let json = try BoardInspectorMachine.make(mode: .occupancy).definitionJSON()
        #expect(json.contains("\"id\":\"board-occupancy\""))
        #expect(json.contains("\"type\":\"parallel\""))
        #expect(json.contains("\"occupied\""))
        #expect(json.contains("\"empty\""))
        #expect(json.contains("SQUARE.OCCUPY.a1.*"))
        #expect(json.contains("SQUARE.CLEAR.h8"))
    }

    @Test("pieces board enumerates piece types through empty")
    func exportsPiecesStructure() throws {
        let json = try BoardInspectorMachine.make(mode: .pieces).definitionJSON()
        #expect(json.contains("\"id\":\"board-pieces\""))
        #expect(json.contains("\"wP\""))
        #expect(json.contains("\"bK\""))
        // Empty routes to each piece type with the dotted type segment.
        #expect(json.contains("SQUARE.OCCUPY.e4.wP.*"))
    }

    @Test("formats starting position as ASCII grid in context")
    func startingGrid() {
        let context = BoardInspectorContext.initial(layout: .standard())
        #expect(context.boardGrid.count == 9)
        #expect(context.boardGrid[0].contains("r n b q k"))
        #expect(context.boardGrid[7].contains("R N B Q K"))
        #expect(context.boardGrid[8] == "  a b c d e f g h")
    }

    @Test("e4 opening flips the boards' square states")
    func mirrorsOpeningMove() async {
        let actor = createActor(GameWatcherMachine.make()).start()
        try? await Task.sleep(for: .milliseconds(100))

        actor.send(Event("TAP.1.4"))
        try? await Task.sleep(for: .milliseconds(30))
        actor.send(Event("TAP.3.4"))
        try? await Task.sleep(for: .milliseconds(80))

        guard let occupancy = actor.childActor(id: BoardInspectorMachine.childId(.occupancy)) as? MachineChildRef<BoardInspectorContext>,
              let pieces = actor.childActor(id: BoardInspectorMachine.childId(.pieces)) as? MachineChildRef<BoardInspectorContext> else {
            Issue.record("board-inspector children missing")
            return
        }

        // Occupancy board: e2 cleared, e4 occupied.
        #expect(occupancy.actor.snapshot.value.matches("e2.empty"))
        #expect(occupancy.actor.snapshot.value.matches("e4.occupied"))

        // Pieces board: e4 now holds the white pawn, e2 is empty.
        #expect(pieces.actor.snapshot.value.matches("e2.empty"))
        #expect(pieces.actor.snapshot.value.matches("e4.wP"))
    }
}
