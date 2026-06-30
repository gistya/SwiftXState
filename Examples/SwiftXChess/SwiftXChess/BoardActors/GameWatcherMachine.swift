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

enum GameWatcherState: String, StateIdentifying {
    case boot, game, active, turn, idle, selecting, promoting, finished, replaying
    static var _blank: GameWatcherState { .boot }
}

/// The chess orchestrator as a typed `StateMachine` (was `enum GameWatcherMachine` + hand-assembled
/// `MachineConfig`/`StateNodeConfig`/`enqueueActions`). `boot` spawns the 96 board actors + 2 inspector
/// boards from its entry, then resolves to `game`; `game.active.turn` runs the play loop
/// (idle/selecting/promoting driven by always-guards over context), with `finished`/`replaying`
/// siblings. Cross-actor board commands now flow through typed `enq.sendTo` (P2a); the
/// `replaying ↔ game.active.turn.idle` jumps are unique-name absolute targets (P2b).
struct GameWatcherMachine: StateMachine {
    typealias Context = GameWatcherContext
    typealias StateID = GameWatcherState
    typealias EventID = ChessEvent

    static let id = "game-watcher"

    /// When `false` (inspector summary), `boot` skips spawning — the graph is the same shape, the
    /// runtime still spawns 96 off-inspector board actors elsewhere.
    let includeBoardSpawns: Bool
    /// When `true`, the 96 per-square/piece board actors stream to inspectors too (a stress test —
    /// kills the web client, fine natively).
    let inspectableBoardActors: Bool

    init(includeBoardSpawns: Bool = true, inspectableBoardActors: Bool = false) {
        self.includeBoardSpawns = includeBoardSpawns
        self.inspectableBoardActors = inspectableBoardActors
    }

    var context: GameWatcherContext { .initial() }

    var machine: some XStateMachine {
        bootState()
        gameState()
    }

    /// - Parameter inspectableBoardActors: when `true`, the 96 per-square/piece board actors
    ///   are streamed to inspectors too (a deliberate stress test — this count kills the web
    ///   client but the native inspector handles it).
    static func make(inspectableBoardActors: Bool = false) -> ResolvedMachine<GameWatcherContext> {
        GameWatcherMachine(includeBoardSpawns: true, inspectableBoardActors: inspectableBoardActors)
            .resolvedMachine(id: id)
    }

    /// Compact graph for Stately Inspector — runtime still spawns 96 off-inspector board actors.
    static func inspectorSummaryMachine() -> ResolvedMachine<GameWatcherContext> {
        GameWatcherMachine(includeBoardSpawns: false).resolvedMachine(id: id)
    }

    // MARK: - States

    private typealias St = XState<GameWatcherContext, ChessEvent, GameWatcherState>
    private typealias Tr = XTransition<GameWatcherContext, ChessEvent, GameWatcherState>

    private func bootState() -> St {
        let boot = XState(.boot) { Always(to: .game) }.initial()
        guard includeBoardSpawns else { return boot }
        let inspectable = inspectableBoardActors
        return boot.onEntry { args, enq in
            BoardActorSpawn.spawnBoard(into: enq, layout: args.context.layout, inspectableBoardActors: inspectable)
            return args.context
        }
    }

    private func gameState() -> St {
        XState(.game) {
            XState(.active) {
                XState(.turn) {
                    XState(.idle) {
                        Always(to: .selecting).when { $0.selected != nil && $0.pendingPromotion == nil }
                        Always(to: .promoting).when { $0.pendingPromotion != nil }
                    }.initial()
                    XState(.selecting) {
                        Always(to: .idle).when { $0.selected == nil }
                        Always(to: .promoting).when { $0.pendingPromotion != nil }
                    }
                    XState(.promoting) {
                        Always(to: .idle).when { $0.pendingPromotion == nil }
                    }
                    tapHandler()
                    promoteHandler()
                    newGameTransition()
                    enterReplayTransition()
                }.initial()
                Always(to: .finished).when { $0.outcome != nil }
            }.initial()
            XState(.finished) {
                newGameTransition()
                enterReplayTransition()
            }
            XState(.replaying) {
                exitReplayTransition()
                newGameTransition()
                scrubHandler()
            }
        }
    }

    // MARK: - Handlers (self-targeting `turn` ≈ internal: the substates are pure functions of context,
    // so the momentary re-entry to `idle` is immediately re-derived by the always-guards).

    private func tapHandler() -> Tr {
        XTransition(on: ChessEvent.tap, to: .turn).action { args, enq in
            var context = args.context
            guard case let .tap(square)? = args.event else { return context }
            // No move: `handleTap` already updated `selected` in `context` — return it.
            guard let commit = GameWatcherRules.handleTap(&context, at: square) else { return context }
            Self.dispatch(commit.commands, into: enq)
            return context
        }
    }

    private func promoteHandler() -> Tr {
        XTransition(on: ChessEvent.promote, to: .turn).action { args, enq in
            var context = args.context
            guard case let .promote(kind)? = args.event,
                  let commit = GameWatcherRules.handlePromotion(&context, piece: kind) else {
                return context
            }
            Self.dispatch(commit.commands, into: enq)
            return context
        }
    }

    private func newGameTransition() -> Tr {
        XTransition(on: .newGame, to: .boot).action { args, enq in
            var context = args.context
            for childId in context.layout.allChildIds { enq.stopChild(childId) }
            let fresh = GameWatcherContext.initial()
            Self.syncContext(&context, from: fresh)
            ChessReplayBridge.clearPendingSession()
            Self.syncBoardInspector(context: context, into: enq)
            return context
        }
    }

    private func enterReplayTransition() -> Tr {
        XTransition(on: .enterReplay, to: .replaying).action { args, _ in
            var context = args.context
            GameWatcherReplay.enter(&context)
            return context
        }
    }

    private func exitReplayTransition() -> Tr {
        XTransition(on: .exitReplay, to: .idle).action { args, _ in
            var context = args.context
            GameWatcherReplay.exit(&context)
            return context
        }
    }

    private func scrubHandler() -> Tr {
        XTransition(on: ChessEvent.replayScrub, to: .replaying).action { args, enq in
            var context = args.context
            if case let .replayScrub(step)? = args.event {
                GameWatcherReplay.syncSnapshot(&context, step: step)
            }
            Self.syncBoardInspector(context: context, into: enq)
            return context
        }
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

    /// Fan a move's board commands out to the typed square/piece children (P2a — payloads survive,
    /// where the old `OCCUPY.<id>` encoded the payload in the event type) plus the string-driven
    /// inspector boards (the inspector speaks its own `SQUARE.*` wildcard vocabulary).
    private static func dispatch(
        _ commands: [GameWatcherCommand],
        into enq: Enqueue<GameWatcherContext, ChessEvent>
    ) {
        for command in commands {
            switch command {
            case let .squareClear(coord):
                enq.sendTo(BoardActorIds.square(coord), SquareEvent.clear)
            case let .squareOccupy(coord, pieceId):
                enq.sendTo(BoardActorIds.square(coord), SquareEvent.occupy(pieceId: pieceId))
            case let .pieceMoveTo(pieceId, coord):
                enq.sendTo(BoardActorIds.piece(id: pieceId), PieceEvent.moveTo(square: coord))
            case let .pieceCaptured(pieceId):
                enq.sendTo(BoardActorIds.piece(id: pieceId), PieceEvent.captured)
            }
            if let inspectorEvent = BoardInspectorSync.inspectorEvent(for: command) {
                for mode in BoardMode.allCases {
                    enq.sendTo(BoardInspectorMachine.childId(mode), inspectorEvent.type)
                }
            }
        }
    }

    private static func syncBoardInspector(
        context: GameWatcherContext,
        into enq: Enqueue<GameWatcherContext, ChessEvent>
    ) {
        for event in BoardInspectorSync.events(occupants: context.occupants, layout: context.layout) {
            for mode in BoardMode.allCases {
                enq.sendTo(BoardInspectorMachine.childId(mode), event.type)
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
