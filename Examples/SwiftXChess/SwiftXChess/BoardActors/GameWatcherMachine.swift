import Foundation
import SwiftXState

struct GameWatcherLiveSnapshot: Sendable, Equatable, Codable {
    var board: Board
    var turn: PieceColor
    var selected: Square?
    var castlingRights: CastlingRights
    var pendingPromotion: PendingPromotion?
    var outcome: GameOutcome?
    var moveHistory: [ChessMove]
    var occupants: [String: String]
    var lastSAN: String?
    var plyCount: Int
}

struct GameWatcherContext: Sendable, Equatable, Codable {
    var board: Board
    var turn: PieceColor
    var selected: Square?
    var castlingRights: CastlingRights
    var pendingPromotion: PendingPromotion?
    var outcome: GameOutcome?
    var moveHistory: [ChessMove]
    var occupants: [String: String]
    var layout: BoardLayoutSeed
    var lastSAN: String?
    var plyCount: Int
    var replaySession: ReplaySession?
    var replayStep: Int
    var liveSnapshot: GameWatcherLiveSnapshot?

    var isReplayMode: Bool { replaySession != nil }

    mutating func captureLiveSnapshot() {
        liveSnapshot = GameWatcherLiveSnapshot(
            board: board,
            turn: turn,
            selected: selected,
            castlingRights: castlingRights,
            pendingPromotion: pendingPromotion,
            outcome: outcome,
            moveHistory: moveHistory,
            occupants: occupants,
            lastSAN: lastSAN,
            plyCount: plyCount
        )
    }

    mutating func restoreLiveSnapshot() {
        guard let liveSnapshot else { return }
        board = liveSnapshot.board
        turn = liveSnapshot.turn
        selected = liveSnapshot.selected
        castlingRights = liveSnapshot.castlingRights
        pendingPromotion = liveSnapshot.pendingPromotion
        outcome = liveSnapshot.outcome
        moveHistory = liveSnapshot.moveHistory
        occupants = liveSnapshot.occupants
        lastSAN = liveSnapshot.lastSAN
        plyCount = liveSnapshot.plyCount
        self.liveSnapshot = nil
    }

    static func initial() -> GameWatcherContext {
        let layout = BoardLayoutSeed.standard()
        var occupants: [String: String] = [:]
        for piece in layout.pieces {
            occupants[piece.square] = piece.id
        }
        return GameWatcherContext(
            board: .standard(),
            turn: .white,
            selected: nil,
            castlingRights: .initial,
            pendingPromotion: nil,
            outcome: nil,
            moveHistory: [],
            occupants: occupants,
            layout: layout,
            lastSAN: nil,
            plyCount: 0,
            replaySession: nil,
            replayStep: 0,
            liveSnapshot: nil
        )
    }
}

enum GameWatcherCommand: Equatable, Sendable {
    case squareClear(String)
    case squareOccupy(coord: String, pieceId: String)
    case pieceMoveTo(pieceId: String, coord: String)
    case pieceCaptured(pieceId: String)
}

enum GameWatcherRules {
    struct MoveCommit: Equatable, Sendable {
        var move: ChessMove
        var san: String
        var commands: [GameWatcherCommand]
    }

    static func handleTap(_ context: inout GameWatcherContext, at square: Square) -> MoveCommit? {
        guard context.outcome == nil, context.pendingPromotion == nil else { return nil }

        if let selected = context.selected {
            if selected == square {
                context.selected = nil
                return nil
            }
            if let move = ChessRules.legalMove(
                from: selected,
                to: square,
                board: context.board,
                turn: context.turn,
                castlingRights: context.castlingRights
            ) {
                if move.piece == .pawn, isPromotionSquare(move.to, color: context.turn) {
                    context.pendingPromotion = PendingPromotion(from: selected, to: square)
                    context.selected = nil
                    return nil
                }
                return completeMove(&context, move: move)
            }
        }

        if let piece = context.board[square], piece.color == context.turn {
            context.selected = square
        } else {
            context.selected = nil
        }
        return nil
    }

    static func handlePromotion(_ context: inout GameWatcherContext, piece kind: PieceKind) -> MoveCommit? {
        guard context.outcome == nil,
              let pending = context.pendingPromotion,
              PieceKind.promotionChoices.contains(kind) else {
            return nil
        }

        guard var move = ChessRules.legalMove(
            from: pending.from,
            to: pending.to,
            board: context.board,
            turn: context.turn,
            castlingRights: context.castlingRights
        ) else {
            context.pendingPromotion = nil
            return nil
        }

        move.promotion = kind
        context.pendingPromotion = nil
        return completeMove(&context, move: move)
    }

    static func commands(
        for move: ChessMove,
        occupants: [String: String]
    ) -> ([GameWatcherCommand], [String: String]) {
        var updated = occupants
        var commands: [GameWatcherCommand] = []

        let fromCoord = BoardActorIds.coord(move.from)
        let toCoord = BoardActorIds.coord(move.to)
        guard let pieceId = updated[fromCoord] else { return ([], occupants) }

        if let capturedId = updated[toCoord] {
            commands.append(.pieceCaptured(pieceId: capturedId))
            // Clear the target square before the capturing piece lands, so the pieces board
            // passes through `empty` (occupied-by-A → empty → occupied-by-B).
            commands.append(.squareClear(toCoord))
            updated.removeValue(forKey: toCoord)
        }

        commands.append(.squareClear(fromCoord))
        commands.append(.pieceMoveTo(pieceId: pieceId, coord: toCoord))
        commands.append(.squareOccupy(coord: toCoord, pieceId: pieceId))
        updated.removeValue(forKey: fromCoord)
        updated[toCoord] = pieceId

        if let castle = move.castle {
            let row = move.from.row
            let rookFromCol = castle == .kingside ? 7 : 0
            let rookToCol = castle == .kingside ? 5 : 3
            let rookFrom = BoardActorIds.coord(Square(row: row, col: rookFromCol))
            let rookTo = BoardActorIds.coord(Square(row: row, col: rookToCol))
            if let rookId = updated[rookFrom] {
                commands.append(.squareClear(rookFrom))
                commands.append(.pieceMoveTo(pieceId: rookId, coord: rookTo))
                commands.append(.squareOccupy(coord: rookTo, pieceId: rookId))
                updated.removeValue(forKey: rookFrom)
                updated[rookTo] = rookId
            }
        }

        return (commands, updated)
    }

    private static func completeMove(
        _ context: inout GameWatcherContext,
        move: ChessMove
    ) -> MoveCommit? {
        let boardBefore = context.board
        let turnBefore = context.turn
        let rightsBefore = context.castlingRights
        guard ChessRules.apply(move, to: &context.board) else { return nil }

        let san = ChessSAN.format(
            move: move,
            board: boardBefore,
            turn: turnBefore,
            castlingRights: rightsBefore
        ) ?? ""

        let (commands, occupants) = commands(for: move, occupants: context.occupants)
        context.occupants = occupants
        updateCastlingRights(move: move, rights: &context.castlingRights)
        context.moveHistory.append(move)
        context.selected = nil
        context.turn = context.turn.opposite
        context.outcome = ChessRules.evaluateOutcome(
            board: context.board,
            turn: context.turn,
            castlingRights: context.castlingRights
        )
        context.lastSAN = san.isEmpty ? nil : san
        context.plyCount += 1

        return MoveCommit(move: move, san: san, commands: commands)
    }

    private static func isPromotionSquare(_ square: Square, color: PieceColor) -> Bool {
        color == .white ? square.row == 7 : square.row == 0
    }

    private static func updateCastlingRights(move: ChessMove, rights: inout CastlingRights) {
        if ChessRules.forfeitsWhiteKingside(move) { rights.whiteKingside = false }
        if ChessRules.forfeitsWhiteQueenside(move) { rights.whiteQueenside = false }
        if ChessRules.forfeitsBlackKingside(move) { rights.blackKingside = false }
        if ChessRules.forfeitsBlackQueenside(move) { rights.blackQueenside = false }
    }
}

enum GameWatcherMachine {
    static let id = "game-watcher"

    /// - Parameter inspectableBoardActors: when `true`, the 96 per-square/piece board actors
    ///   are streamed to inspectors too (a deliberate stress test — this count kills the web
    ///   client but the native inspector handles it).
    static func make(inspectableBoardActors: Bool = false) -> StateMachine<GameWatcherContext> {
        machineConfig(includeBoardSpawns: true, inspectableBoardActors: inspectableBoardActors)
    }

    /// Compact graph for Stately Inspector — runtime still spawns 96 off-inspector board actors.
    static func inspectorSummaryMachine() -> StateMachine<GameWatcherContext> {
        machineConfig(includeBoardSpawns: false, inspectableBoardActors: false)
    }

    private static func machineConfig(includeBoardSpawns: Bool, inspectableBoardActors: Bool) -> StateMachine<GameWatcherContext> {
        let initial = GameWatcherContext.initial()
        var boot = StateNodeConfig<GameWatcherContext>(always: [TransitionConfig(target: "game")])
        if includeBoardSpawns {
            boot.entry = BoardActorSpawn.entryActions(layout: initial.layout, inspectableBoardActors: inspectableBoardActors)
        }
        let description = includeBoardSpawns
            ? "Chess orchestrator — one inspector graph; 96 board actors run off-inspector"
            : "Chess orchestrator (inspector summary; 96 board actors run off-graph)"
        return createMachine(
            MachineConfig(
                id: id,
                initial: "boot",
                context: initial,
                states: [
                    "boot": boot,
                    "game": gameState(),
                ],
                description: description
            ),
            implementations: implementations()
        )
    }

    private static func implementations() -> MachineImplementations<GameWatcherContext> {
        MachineImplementations.legacy(
            guards: [
                "hasSelection": { args in
                    args.context.selected != nil && args.context.pendingPromotion == nil
                },
                "noSelection": { args in args.context.selected == nil },
                "hasPromotion": { args in args.context.pendingPromotion != nil },
                "noPromotion": { args in args.context.pendingPromotion == nil },
                "hasOutcome": { args in args.context.outcome != nil },
            ]
        )
    }

    private static func gameState() -> StateNodeConfig<GameWatcherContext> {
        StateNodeConfig(
            initial: "active",
            states: [
                "active": StateNodeConfig(
                    initial: "turn",
                    states: [
                        "turn": StateNodeConfig(
                            initial: "idle",
                            states: [
                                "idle": StateNodeConfig(
                                    always: [
                                        TransitionConfig(
                                            target: "selecting",
                                            guard: .named("hasSelection")
                                        ),
                                        TransitionConfig(
                                            target: "promoting",
                                            guard: .named("hasPromotion")
                                        ),
                                    ]
                                ),
                                "selecting": StateNodeConfig(
                                    always: [
                                        TransitionConfig(
                                            target: "idle",
                                            guard: .named("noSelection")
                                        ),
                                        TransitionConfig(
                                            target: "promoting",
                                            guard: .named("hasPromotion")
                                        ),
                                    ]
                                ),
                                "promoting": StateNodeConfig(
                                    always: [
                                        TransitionConfig(
                                            target: "idle",
                                            guard: .named("noPromotion")
                                        ),
                                    ]
                                ),
                            ],
                            on: interactionHandlers()
                        ),
                    ],
                    always: [
                        TransitionConfig(target: "finished", guard: .named("hasOutcome")),
                    ]
                ),
                "finished": StateNodeConfig(
                    on: [
                        ChessEvent.newGame.type: .single(
                            TransitionConfig(target: "boot", actions: newGameActions())
                        ),
                        ChessEvent.enterReplay.type: .single(
                            TransitionConfig(target: "#game-watcher.game.replaying", actions: [assign { ctx, _ in
                                GameWatcherReplay.enter(&ctx)
                            }])
                        ),
                    ]
                ),
                "replaying": StateNodeConfig(
                    on: [
                        ChessEvent.exitReplay.type: .single(
                            TransitionConfig(
                                target: "#game-watcher.game.active.turn.idle",
                                actions: [assign { ctx, _ in
                                    GameWatcherReplay.exit(&ctx)
                                }]
                            )
                        ),
                        ChessEvent.newGame.type: .single(
                            TransitionConfig(target: "boot", actions: newGameActions())
                        ),
                        "REPLAY_SCRUB.*": .single(TransitionConfig(actions: [
                            enqueueActions { builder in
                                builder.enqueue(assign { ctx, args in
                                    GameWatcherReplay.scrub(&ctx, args: args)
                                })
                                syncBoardInspector(builder: builder)
                            },
                        ])),
                    ]
                ),
            ]
        )
    }

    private static func interactionHandlers() -> [String: TransitionInput<GameWatcherContext>] {
        let handlers: [String: TransitionInput<GameWatcherContext>] = [
            "TAP.*": .single(TransitionConfig(actions: [
                enqueueActions { builder in
                    var context = builder.context
                    guard let event = ChessEvent.parse(builder.event),
                          case let .tap(square) = event else { return }
                    guard let commit = GameWatcherRules.handleTap(&context, at: square) else {
                        let selected = context.selected
                        builder.enqueue(assign { ctx, _ in
                            ctx.selected = selected
                        })
                        return
                    }
                    let updated = context
                    builder.enqueue(assign { ctx, _ in
                        syncContext(&ctx, from: updated)
                    })
                    dispatch(commit.commands, builder: builder)
                },
            ])),
            "PROMOTE.*": .single(TransitionConfig(actions: [
                enqueueActions { builder in
                    var context = builder.context
                    guard let event = ChessEvent.parse(builder.event),
                          case let .promote(kind) = event,
                          let commit = GameWatcherRules.handlePromotion(&context, piece: kind) else {
                        return
                    }
                    let updated = context
                    builder.enqueue(assign { ctx, _ in
                        syncContext(&ctx, from: updated)
                    })
                    dispatch(commit.commands, builder: builder)
                },
            ])),
            ChessEvent.newGame.type: .single(
                TransitionConfig(target: "boot", actions: newGameActions())
            ),
            ChessEvent.enterReplay.type: .single(
                TransitionConfig(target: "#game-watcher.game.replaying", actions: [assign { ctx, _ in
                    GameWatcherReplay.enter(&ctx)
                }])
            ),
        ]
        return handlers
    }

    private static func newGameActions() -> [ActionRef<GameWatcherContext>] {
        [
            enqueueActions { builder in
                for childId in builder.context.layout.allChildIds {
                    builder.enqueue(stopChild(childId))
                }
                builder.enqueue(assign { ctx, _ in
                    let fresh = GameWatcherContext.initial()
                    syncContext(&ctx, from: fresh)
                    ChessReplayBridge.clearPendingSession()
                })
                syncBoardInspector(builder: builder)
            },
        ]
    }

    private static func syncContext(_ target: inout GameWatcherContext, from source: GameWatcherContext) {
        target.board = source.board
        target.turn = source.turn
        target.selected = source.selected
        target.castlingRights = source.castlingRights
        target.pendingPromotion = source.pendingPromotion
        target.outcome = source.outcome
        target.moveHistory = source.moveHistory
        target.occupants = source.occupants
        target.layout = source.layout
        target.lastSAN = source.lastSAN
        target.plyCount = source.plyCount
        target.replaySession = source.replaySession
        target.replayStep = source.replayStep
        target.liveSnapshot = source.liveSnapshot
    }

    private static func dispatch(
        _ commands: [GameWatcherCommand],
        builder: EnqueueActionsBuilder<GameWatcherContext>
    ) {
        for command in commands {
            switch command {
            case let .squareClear(coord):
                builder.sendTo(BoardActorIds.square(coord), Event("CLEAR"))
            case let .squareOccupy(coord, pieceId):
                builder.sendTo(BoardActorIds.square(coord), Event("OCCUPY.\(pieceId)"))
            case let .pieceMoveTo(pieceId, coord):
                builder.sendTo(BoardActorIds.piece(id: pieceId), Event("MOVE_TO.\(coord)"))
            case let .pieceCaptured(pieceId):
                builder.sendTo(BoardActorIds.piece(id: pieceId), Event("CAPTURED"))
            }
            if let inspectorEvent = BoardInspectorSync.inspectorEvent(for: command) {
                for mode in BoardMode.allCases {
                    builder.sendTo(BoardInspectorMachine.childId(mode), inspectorEvent)
                }
            }
        }
    }

    private static func syncBoardInspector(builder: EnqueueActionsBuilder<GameWatcherContext>) {
        for event in BoardInspectorSync.events(
            occupants: builder.context.occupants,
            layout: builder.context.layout
        ) {
            for mode in BoardMode.allCases {
                builder.sendTo(BoardInspectorMachine.childId(mode), event)
            }
        }
    }
}

enum GameWatcherReplay {
    static func enter(_ context: inout GameWatcherContext) {
        guard let session = ChessReplayBridge.takePendingSession() else { return }
        context.captureLiveSnapshot()
        context.replaySession = session
        syncSnapshot(&context, step: lastStepIndex(in: session))
    }

    static func lastStepIndex(in session: ReplaySession) -> Int {
        max(session.steps.count - 1, 0)
    }

    static func exit(_ context: inout GameWatcherContext) {
        context.replaySession = nil
        context.replayStep = 0
        context.restoreLiveSnapshot()
    }

    static func scrub(_ context: inout GameWatcherContext, args: ActionArgs<GameWatcherContext>) {
        guard let event = ChessEvent.parse(args.event),
              case let .replayScrub(step) = event else {
            return
        }
        syncSnapshot(&context, step: step)
    }

    static func syncSnapshot(_ context: inout GameWatcherContext, step: Int) {
        guard let session = context.replaySession else { return }
        let clamped = min(max(step, 0), max(session.steps.count - 1, 0))
        GameWatcherReplayRestore.apply(
            stepIndex: clamped,
            recorded: session.steps[clamped],
            session: session,
            to: &context
        )
    }
}
