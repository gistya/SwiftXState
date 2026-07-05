import Foundation
import SwiftXState

/// Every state in the chess machine. The machine *root* is parallel (`isParallel`) over the two
/// top-level regions: `game` is a compound (playing / gameOver / replaying); `castling` is parallel
/// over four sides, each a compound `available` / `forfeited`. (`available` / `forfeited` are shared
/// across the four sides — the typed `Configuration` keeps them distinct by their parent path.)
enum ChessState: String, StateIdentifying {
    case game, castling
    case playing, gameOver, replaying
    case whiteKingside, whiteQueenside, blackKingside, blackQueenside
    case available, forfeited

    static var _blank: ChessState { .game }
}

/// The chess game as a typed `StateMachine` — was `ChessMachineFactory` over `createMachine` /
/// `MachineConfig` / `StateNodeConfig` with `setup(guards:)` named guards. Taps drive `game`
/// (`ChessRules.handleTap`) and, in parallel, the `castling` region's per-side **event-aware** forfeit
/// guards (`.when { ctx, event in … }`).
struct ChessGameMachine: StateMachine {
    typealias Context = ChessContext
    typealias StateID = ChessState
    typealias EventID = ChessEvent

    static let id = "chess"

    /// The resolved engine machine — for replay time-travel, `verifyReplay`, inspector registration,
    /// and graph visualization (anywhere a `ResolvedMachine` is needed rather than a running actor).
    static var resolved: ResolvedMachine<ChessContext> { ChessGameMachine().resolvedMachine(id: id) }

    var context: ChessContext { .initial() }

    /// Root is parallel: the `game` and `castling` regions run at once (was a `.root` parallel wrapper
    /// state — `isParallel` drops the extra `root.` path segment).
    var isParallel: Bool { true }

    var machine: some XStateMachine {
        // ── game region ──────────────────────────────────────────────────────────────────
        State(.game) {
            State(.playing) {
                    Transition(on: .tap, to: .playing).action { args, _ in
                        var ctx = args.context
                        guard ctx.replaySession == nil, case let .tap(square)? = args.event else { return ctx }
                        ChessRules.handleTap(&ctx, at: square)
                        return ctx
                    }
                
                    Transition(on: .promote, to: .playing).action { args, _ in
                        var ctx = args.context
                        guard ctx.replaySession == nil, case let .promote(kind)? = args.event else { return ctx }
                        ChessRules.handlePromotion(&ctx, piece: kind)
                        return ctx
                    }
                
                    Transition(on: .newGame, to: .playing).action(Self.resetGame)
                    Transition(on: .enterReplay, to: .replaying).action(Self.enterReplay)
                    Always(to: .gameOver).when { $0.outcome != nil }
                }
                .initial()

                State(.gameOver) {
                    Transition(on: .newGame, to: .playing).action(Self.resetGame)
                    Transition(on: .enterReplay, to: .replaying).action(Self.enterReplay)
                }

                State(.replaying) {
                    Transition(on: .exitReplay, to: .playing).action(Self.exitReplay)
                    Transition(on: .newGame, to: .playing).action(Self.resetGame)
                    Transition(on: .replayScrub, to: .replaying).action { args, _ in
                        var ctx = args.context
                        guard case let .replayScrub(step)? = args.event else { return ctx }
                        Self.syncReplaySnapshot(&ctx, step)
                        return ctx
                    }
                }
            }

        // ── castling region (parallel over the four sides) ───────────────────────────────
        State(.castling) {
            castlingSide(.whiteKingside, forfeits: ChessRules.forfeitsWhiteKingside)
            castlingSide(.whiteQueenside, forfeits: ChessRules.forfeitsWhiteQueenside)
            castlingSide(.blackKingside, forfeits: ChessRules.forfeitsBlackKingside)
            castlingSide(.blackQueenside, forfeits: ChessRules.forfeitsBlackQueenside)
        }
        .parallel()
    }

    /// One castling side: `available` until a tap implies a move that forfeits this side's rights,
    /// then `forfeited`; `newGame` resets to `available`. The forfeit check is an **event-aware**
    /// guard — it needs the tapped square from the event, not just context.
    private func castlingSide(
        _ id: ChessState,
        forfeits: @escaping @Sendable (ChessMove) -> Bool
    ) -> State {
        State(id) {
            State(.available) {
                Transition(on: ChessEvent.tap, to: .forfeited).when { ctx, event in
                    guard case let .tap(to)? = event, let move = ChessRules.pendingMove(ctx, to: to) else { return false }
                    return forfeits(move)
                }
                
                Transition(on: .newGame, to: .available)
            }
            .initial()

            State(.forfeited) {
                Transition(on: .newGame, to: .available)
            }
        }
    }

    // MARK: - Action handlers (call ChessRules / the replay bridge; logic unchanged from the factory)

    static let resetGame: @Sendable (_: consuming ChessContext) -> ChessContext = { _ in
        ChessReplayBridge.clearPendingSession()
        return ChessContext.initial()
    }

    static let enterReplay: @Sendable (_ context: consuming ChessContext) -> ChessContext = { context in
        var ctx = context
        guard let session = ChessReplayBridge.takePendingSession() else { return ctx }
        ctx.captureLiveSnapshot()
        ctx.replaySession = session
        syncReplaySnapshot(&ctx, max(session.steps.count - 1, 0))
        return ctx
    }

    static let exitReplay: @Sendable (_ context: consuming ChessContext) -> ChessContext =  { context in
        var ctx = context
        ctx.replaySession = nil
        ctx.replayStep = 0
        ctx.restoreLiveSnapshot()
        return ctx
    }

    static let syncReplaySnapshot: @Sendable (_ context: inout ChessContext, _ step: Int) -> Void = { context, step in
        guard let session = context.replaySession else { return }
        let clamped = min(max(step, 0), max(session.steps.count - 1, 0))
        ChessReplayRestore.apply(
            stepIndex: clamped,
            recorded: session.steps[clamped],
            session: session,
            to: &context
        )
    }
}

/// Bridges UI-recorded sessions into machine actions (unchanged).
enum ChessReplayBridge {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var pendingSession: ReplaySession?

    static func setPendingSession(_ session: ReplaySession?) {
        lock.lock(); pendingSession = session; lock.unlock()
    }

    static func takePendingSession() -> ReplaySession? {
        lock.lock(); defer { lock.unlock() }
        let session = pendingSession
        pendingSession = nil
        return session
    }

    static func clearPendingSession() {
        lock.lock(); pendingSession = nil; lock.unlock()
    }
}

extension Map where In == Int, Out == ChessEvent {
    static var replayScrub: Map<In, Out> { .init(transform: Out.replayScrub) }
}

extension Map where In == Square, Out == ChessEvent {
    static var tap: Map<In, Out> { .init(transform: Out.tap) }
}

extension Map where In == PieceKind, Out == ChessEvent {
    static var promote: Map<In, Out> { .init(transform: Out.promote) }
}
