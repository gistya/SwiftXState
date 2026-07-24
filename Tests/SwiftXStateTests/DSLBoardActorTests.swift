import Testing
@testable import SwiftXState

/// Mirrors the migrated SwiftXChess `SquareActorMachine` / `PieceActorMachine` (which live in the
/// unbuildable-here .xcodeproj) so their typed-DSL logic is verified in-package: boot resolving from
/// seeded context, payload events, and the always-guards.
@Suite("SwiftXChess Phase 1 — board actor machines")
struct DSLBoardActorTests {
    // MARK: Square

    struct SquareCtx: Sendable, Equatable, Hashable { var occupantId: String?; var isOccupied: Bool { occupantId != nil } }
    enum SqState: String, StateIdentifying { case boot, empty, occupied; static var _blank: SqState { .boot } }
    enum SqEvent: EventIdentifying {
        case occupy(pieceId: String); case clear; case sync(occupantId: String?)
        static var _blank: SqEvent { .clear }
    }
    struct Square: StateMachine {
        typealias Context = SquareCtx; typealias StateID = SqState; typealias EventID = SqEvent
        var context: SquareCtx { .init(occupantId: nil) }
        var machine: some XStateMachine {
            XState(.boot) {
                Always(to: .occupied).when { $0.isOccupied }
                Always(to: .empty)
            }.initial()
            XState(.empty) {
                XTransition(on: SqEvent.occupy, to: .occupied).action { a, _ in
                    var c = a.context; if case let .occupy(p)? = a.event { c.occupantId = p }; return c
                }
                XTransition(on: SqEvent.sync, to: .empty).action { a, _ in
                    var c = a.context; if case let .sync(o)? = a.event { c.occupantId = o }; return c
                }
                Always(to: .occupied).when { $0.isOccupied }
            }
            XState(.occupied) {
                XTransition(on: .clear, to: .empty).action { c in var x = c; x.occupantId = nil; return x }
                XTransition(on: SqEvent.occupy, to: .occupied).action { a, _ in
                    var c = a.context; if case let .occupy(p)? = a.event { c.occupantId = p }; return c
                }
                XTransition(on: SqEvent.sync, to: .occupied).action { a, _ in
                    var c = a.context; if case let .sync(o)? = a.event { c.occupantId = o }; return c
                }
                Always(to: .empty).when { !$0.isOccupied }
            }
        }
    }

    @Test func squareBootResolvesFromSeed() async {
        let empty = createActor(Square())
        await empty.start()
        #expect(await empty.matches(.empty))

        let occupied = createActor(Square())
        await occupied.start(context: SquareCtx(occupantId: "wP"))
        #expect(await occupied.matches(.occupied))
    }

    @Test func squareTracksOccupancy() async {
        let sq = createActor(Square())
        await sq.start()
        #expect(await sq.matches(.empty))

        await sq.send(.occupy(pieceId: "wP"))
        #expect(await sq.matches(.occupied))
        #expect(await sq.context.occupantId == "wP")

        await sq.send(.clear)
        #expect(await sq.matches(.empty))

        // sync sets the occupant, and the always-guard re-routes to occupied.
        await sq.send(.sync(occupantId: "bN"))
        #expect(await sq.matches(.occupied))
        #expect(await sq.context.occupantId == "bN")
    }

    // MARK: Piece

    struct PieceCtx: Sendable, Equatable { var square: String?; var isAlive: Bool { square != nil } }
    enum PcState: String, StateIdentifying { case boot, alive, captured; static var _blank: PcState { .boot } }
    enum PcEvent: EventIdentifying {
        case moveTo(square: String); case captured; case sync(square: String?)
        static var _blank: PcEvent { .captured }
    }
    struct Piece: StateMachine {
        typealias Context = PieceCtx; typealias StateID = PcState; typealias EventID = PcEvent
        var context: PieceCtx { .init(square: nil) }
        var machine: some XStateMachine {
            XState(.boot) {
                Always(to: .alive).when { $0.isAlive }
                Always(to: .captured)
            }.initial()
            XState(.alive) {
                XTransition(on: PcEvent.moveTo, to: .alive).action { a, _ in
                    var c = a.context; if case let .moveTo(s)? = a.event { c.square = s }; return c
                }
                XTransition(on: .captured, to: .captured).action { c in var x = c; x.square = nil; return x }
                XTransition(on: PcEvent.sync, to: .alive).action { a, _ in
                    var c = a.context; if case let .sync(s)? = a.event { c.square = s }; return c
                }
                Always(to: .captured).when { !$0.isAlive }
            }
            XState(.captured) {
                XTransition(on: PcEvent.sync, to: .captured).action { a, _ in
                    var c = a.context; if case let .sync(s)? = a.event { c.square = s }; return c
                }
                Always(to: .alive).when { $0.isAlive }
            }
        }
    }

    @Test func pieceTracksLifeAndPosition() async {
        let p = createActor(Piece())
        await p.start(context: PieceCtx(square: "a2"))
        #expect(await p.matches(.alive))

        await p.send(.moveTo(square: "a4"))
        #expect(await p.context.square == "a4")

        await p.send(.captured)
        #expect(await p.matches(.captured))
        #expect(await p.context.square == nil)

        // sync to a square revives via the always-guard; sync to nil stays captured.
        await p.send(.sync(square: "h8"))
        #expect(await p.matches(.alive))
        #expect(await p.context.square == "h8")
    }
}
