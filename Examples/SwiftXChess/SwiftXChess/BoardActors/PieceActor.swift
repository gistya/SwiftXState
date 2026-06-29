import Foundation
import SwiftXState

struct PieceContext: Sendable, Equatable, Codable {
    var pieceId: String
    var kind: PieceKind
    var color: PieceColor
    var square: String?

    var isAlive: Bool { square != nil }
}

enum PieceState: String, StateIdentifying {
    case boot, alive, captured
    static var _blank: PieceState { .boot }
}

/// Typed payload events — `MOVE_TO.<sq>` / `SYNC.<sq>` / `SYNC.off` type-string encoding + `parse(_:)`
/// gone; payload read off `args.event`.
enum PieceEvent: EventIdentifying {
    case moveTo(square: String)
    case captured
    case sync(square: String?)

    static var _blank: PieceEvent { .captured }
}

/// A piece as a typed `StateMachine`: `boot` resolves to `alive`/`captured` from its seeded square,
/// then tracks position via events. The old machine had two `SYNC` handlers (`SYNC.*` vs `SYNC.off`);
/// here one `.sync` transition + an `Always` guard subsumes both.
struct PieceActorMachine: StateMachine {
    typealias Context = PieceContext
    typealias StateID = PieceState
    typealias EventID = PieceEvent

    static let id = "piece"

    var context: PieceContext { PieceContext(pieceId: "wPa2", kind: .pawn, color: .white, square: nil) }

    var machine: some XStateMachine {
        XState(.boot) {
            Always(to: .alive).when { $0.isAlive }
            Always(to: .captured)
        }
        .initial()

        XState(.alive) {
            XTransition(on: PieceEvent.moveTo, to: .alive).action { args, _ in
                var ctx = args.context
                if case let .moveTo(square)? = args.event { ctx.square = square }
                return ctx
            }
            XTransition(on: .captured, to: .captured).action { ctx in
                var c = ctx; c.square = nil; return c
            }
            XTransition(on: PieceEvent.sync, to: .alive).action { args, _ in
                var ctx = args.context
                if case let .sync(square)? = args.event { ctx.square = square }
                return ctx
            }
            Always(to: .captured).when { !$0.isAlive }
        }

        XState(.captured) {
            XTransition(on: PieceEvent.sync, to: .captured).action { args, _ in
                var ctx = args.context
                if case let .sync(square)? = args.event { ctx.square = square }
                return ctx
            }
            Always(to: .alive).when { $0.isAlive }
        }
    }
}
