import Testing
@testable import SwiftXState

/// Mirrors the migrated SwiftXChess `ChessGameMachine` *structure* (which lives in the unbuildable-here
/// .xcodeproj): a parallel `root` over a `game` compound and a `castling` parallel region of four
/// sides, the four sides sharing `available`/`forfeited` state names (kept distinct by path), and the
/// per-side **event-aware** forfeit guards. Stub handlers stand in for ChessRules.
@Suite("SwiftXChess Phase 1 — ChessMachine structure (parallel root + castling)")
struct DSLChessStructureTests {
    struct Ctx: Sendable, Equatable { var outcome = false; var selected: Int? }
    enum St: String, StateIdentifying {
        case root, game, castling, playing, gameOver, replaying
        case wk, wq, bk, bq, available, forfeited
        static var _blank: St { .root }
    }
    enum Ev: EventIdentifying {
        case tap(Int), newGame, enterReplay, exitReplay
        static var _blank: Ev { .newGame }
    }

    struct ChessLike: StateMachine {
        typealias Context = Ctx; typealias StateID = St; typealias EventID = Ev
        var context: Ctx { .init() }
        var machine: some XStateMachine {
            XState(.root) {
                XState(.game) {
                    XState(.playing) {
                        XTransition(on: Ev.tap, to: .playing).action { args, _ in
                            var c = args.context
                            if case let .tap(v)? = args.event { c.selected = v; if v == 99 { c.outcome = true } }
                            return c
                        }
                        XTransition(on: .newGame, to: .playing).action { _ in Ctx() }
                        XTransition(on: .enterReplay, to: .replaying)
                        Always(to: .gameOver).when { $0.outcome }
                    }.initial()
                    XState(.gameOver) {
                        XTransition(on: .newGame, to: .playing).action { _ in Ctx() }
                    }
                    XState(.replaying) {
                        XTransition(on: .exitReplay, to: .playing)
                    }
                }
                XState(.castling) {
                    side(.wk) { $0 == 1 }
                    side(.wq) { $0 == 2 }
                    side(.bk) { $0 == 3 }
                    side(.bq) { $0 == 4 }
                }.parallel()
            }
            .parallel()
            .initial()
        }
        func side(_ id: St, forfeits: @escaping @Sendable (Int) -> Bool) -> XState<Ctx, Ev, St> {
            XState(id) {
                XState(.available) {
                    XTransition(on: Ev.tap, to: .forfeited).when { _, event in
                        if case let .tap(v)? = event { return forfeits(v) }
                        return false
                    }
                    XTransition(on: .newGame, to: .available)
                }.initial()
                XState(.forfeited) {
                    XTransition(on: .newGame, to: .available)
                }
            }
        }
    }

    @Test func startsInGamePlayingAndAllCastlingAvailable() async {
        let m = createActor(ChessLike())
        await m.start()
        #expect(await m.matches(path: "root.game.playing"))
        for side in ["wk", "wq", "bk", "bq"] {
            #expect(await m.matches(path: "root.castling.\(side).available"))
        }
    }

    @Test func tapForfeitsOnlyTheMatchingSide() async {
        let m = createActor(ChessLike())
        await m.start()

        await m.send(.tap(1))   // forfeits whiteKingside only
        #expect(await m.matches(path: "root.castling.wk.forfeited"))
        #expect(await m.matches(path: "root.castling.wq.available"))   // shared name, distinct by path
        #expect(await m.matches(path: "root.castling.bk.available"))
        #expect(await m.matches(path: "root.game.playing"))            // game ran in parallel, stayed playing

        await m.send(.tap(3))   // forfeits blackKingside; whiteKingside stays forfeited
        #expect(await m.matches(path: "root.castling.bk.forfeited"))
        #expect(await m.matches(path: "root.castling.wk.forfeited"))
    }

    @Test func outcomeMovesGameToGameOverButNotCastling() async {
        let m = createActor(ChessLike())
        await m.start()
        await m.send(.tap(99))   // sets outcome → always → gameOver
        #expect(await m.matches(path: "root.game.gameOver"))
        #expect(await m.matches(path: "root.castling.wk.available"))   // castling untouched
    }

    @Test func newGameResetsBothRegions() async {
        let m = createActor(ChessLike())
        await m.start()
        await m.send(.tap(1))    // forfeit wk
        await m.send(.tap(99))   // → gameOver
        #expect(await m.matches(path: "root.game.gameOver"))
        #expect(await m.matches(path: "root.castling.wk.forfeited"))

        await m.send(.newGame)   // reaches both regions in parallel
        #expect(await m.matches(path: "root.game.playing"))
        #expect(await m.matches(path: "root.castling.wk.available"))
    }
}
