import SwiftXState

enum BoardActorSpawn {
    /// Spawn the full board into the GameWatcher from its `boot` entry: 64 square actors + 32 piece
    /// actors + the 2 inspector boards. Each square/piece is seeded with its own context via
    /// `enq.spawn`'s `context:` override (was `spawnChild(fromMachine(...), input:)` with the context
    /// threaded through a `SendableValue` input). The inspector boards carry their layout-derived
    /// context directly on the machine.
    ///
    /// - Parameter inspectableBoardActors: when `true`, the 96 per-square/piece board actors are
    ///   streamed to inspectors too (a deliberate stress test — kills the web client, fine natively).
    static func spawnBoard(
        into enq: Enqueue<GameWatcherContext, ChessEvent>,
        layout: BoardLayoutSeed,
        inspectableBoardActors: Bool
    ) {
        for square in layout.squares {
            enq.spawn(
                SquareActorMachine(),
                id: BoardActorIds.square(square.coord),
                context: SquareContext(coord: square.coord, occupantId: square.occupantId),
                systemId: SquareActorMachine.id,
                inspectable: inspectableBoardActors
            )
        }
        for piece in layout.pieces {
            enq.spawn(
                PieceActorMachine(),
                id: BoardActorIds.piece(id: piece.id),
                context: PieceContext(
                    pieceId: piece.id,
                    kind: piece.kind,
                    color: piece.color,
                    square: piece.square
                ),
                systemId: PieceActorMachine.id,
                inspectable: inspectableBoardActors
            )
        }
        // Spawn both board representations as separate inspectable actors — pick either in the
        // inspector's actor drawer to swap between the occupancy and pieces views.
        for mode in BoardMode.allCases {
            enq.spawn(
                BoardInspectorMachine(mode: mode, layout: layout),
                id: BoardInspectorMachine.childId(mode),
                systemId: BoardInspectorMachine.id(mode),
                inspectable: true
            )
        }
    }
}
