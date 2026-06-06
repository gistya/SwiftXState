import Foundation
import SwiftXState

enum BoardActorSpawn {
    static func entryActions(layout: BoardLayoutSeed, inspectableBoardActors: Bool = false) -> [ActionRef<GameWatcherContext>] {
        var actions: [ActionRef<GameWatcherContext>] = []
        for square in layout.squares {
            let childId = BoardActorIds.square(square.coord)
            let context = SquareContext(coord: square.coord, occupantId: square.occupantId)
            actions.append(
                spawnChild(
                    fromMachine(SquareActorMachine.machine, context: { input in
                        input?.get(SquareContext.self) ?? context
                    }),
                    id: childId,
                    systemId: SquareActorMachine.id,
                    input: { _ in SendableValue(context) },
                    syncSnapshot: false,
                    inspectable: inspectableBoardActors
                )
            )
        }
        for piece in layout.pieces {
            let childId = BoardActorIds.piece(id: piece.id)
            let context = PieceContext(
                pieceId: piece.id,
                kind: piece.kind,
                color: piece.color,
                square: piece.square
            )
            actions.append(
                spawnChild(
                    fromMachine(PieceActorMachine.machine, context: { input in
                        input?.get(PieceContext.self) ?? context
                    }),
                    id: childId,
                    systemId: PieceActorMachine.id,
                    input: { _ in SendableValue(context) },
                    syncSnapshot: false,
                    inspectable: inspectableBoardActors
                )
            )
        }
        // Spawn both board representations as separate inspectable actors — pick either in the
        // inspector's actor drawer to swap between the occupancy and pieces views.
        for mode in BoardMode.allCases {
            actions.append(inspectorSpawn(mode: mode, layout: layout))
        }
        return actions
    }

    static func inspectorSpawn(mode: BoardMode, layout: BoardLayoutSeed) -> ActionRef<GameWatcherContext> {
        let context = BoardInspectorContext.initial(layout: layout)
        return spawnChild(
            fromMachine(BoardInspectorMachine.make(mode: mode, layout: layout), context: { input in
                input?.get(BoardInspectorContext.self) ?? context
            }),
            id: BoardInspectorMachine.childId(mode),
            systemId: BoardInspectorMachine.id(mode),
            input: { _ in SendableValue(context) },
            syncSnapshot: false,
            inspectable: true
        )
    }
}
