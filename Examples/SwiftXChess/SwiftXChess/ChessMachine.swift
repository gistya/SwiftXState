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
        XState(.game) {
            XState(.playing) {
                    XTransition(on: ChessEvent.tap, to: .playing).action { args, _ in
                        var ctx = args.context
                        guard ctx.replaySession == nil, case let .tap(square)? = args.event else { return ctx }
                        ChessRules.handleTap(&ctx, at: square)
                        return ctx
                    }
                    XTransition(on: ChessEvent.promote, to: .playing).action { args, _ in
                        var ctx = args.context
                        guard ctx.replaySession == nil, case let .promote(kind)? = args.event else { return ctx }
                        ChessRules.handlePromotion(&ctx, piece: kind)
                        return ctx
                    }
                    XTransition(on: .newGame, to: .playing).action(Self.resetGame)
                    XTransition(on: .enterReplay, to: .replaying).action(Self.enterReplay)
                    Always(to: .gameOver).when { $0.outcome != nil }
                }
                .initial()

                XState(.gameOver) {
                    XTransition(on: .newGame, to: .playing).action(Self.resetGame)
                    XTransition(on: .enterReplay, to: .replaying).action(Self.enterReplay)
                }

                XState(.replaying) {
                    XTransition(on: .exitReplay, to: .playing).action(Self.exitReplay)
                    XTransition(on: .newGame, to: .playing).action(Self.resetGame)
                    XTransition(on: ChessEvent.replayScrub, to: .replaying).action { args, _ in
                        var ctx = args.context
                        guard case let .replayScrub(step)? = args.event else { return ctx }
                        Self.syncReplaySnapshot(&ctx, step: step)
                        return ctx
                    }
                }
            }

        // ── castling region (parallel over the four sides) ───────────────────────────────
        XState(.castling) {
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
    ) -> XState<ChessContext, ChessEvent, ChessState> {
        XState(id) {
            XState(.available) {
                XTransition(on: ChessEvent.tap, to: .forfeited).when { ctx, event in
                    guard case let .tap(to)? = event, let move = ChessRules.pendingMove(ctx, to: to) else { return false }
                    return forfeits(move)
                }
                XTransition(on: .newGame, to: .available)
            }
            .initial()

            XState(.forfeited) {
                XTransition(on: .newGame, to: .available)
            }
        }
    }

    // MARK: - Action handlers (call ChessRules / the replay bridge; logic unchanged from the factory)

    static func resetGame(_: consuming ChessContext) -> ChessContext {
        ChessReplayBridge.clearPendingSession()
        return ChessContext.initial()
    }

    static func enterReplay(_ context: consuming ChessContext) -> ChessContext {
        var ctx = context
        guard let session = ChessReplayBridge.takePendingSession() else { return ctx }
        ctx.captureLiveSnapshot()
        ctx.replaySession = session
        syncReplaySnapshot(&ctx, step: max(session.steps.count - 1, 0))
        return ctx
    }

    static func exitReplay(_ context: consuming ChessContext) -> ChessContext {
        var ctx = context
        ctx.replaySession = nil
        ctx.replayStep = 0
        ctx.restoreLiveSnapshot()
        return ctx
    }

    static func syncReplaySnapshot(_ context: inout ChessContext, step: Int) {
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
