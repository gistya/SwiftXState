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
        State(.boot) {
            Always(to: .alive).when { $0.isAlive }
            Always(to: .captured)
        }
        .initial()

        State(.alive) {
            Transition(on: .moveTo, to: .alive).action { args, _ in
                var ctx = args.context
                if case let .moveTo(square)? = args.event { ctx.square = square }
                return ctx
            }
            
            Transition(on: .captured, to: .captured).action { ctx in
                var c = ctx; c.square = nil; return c
            }
            
            Transition(on: .sync, to: .alive).action { args, _ in
                var ctx = args.context
                if case let .sync(square)? = args.event { ctx.square = square }
                return ctx
            }
            
            Always(to: .captured).when { !$0.isAlive }
        }

        State(.captured) {
            Transition(on: .sync, to: .captured).action { args, _ in
                var ctx = args.context
                if case let .sync(square)? = args.event { ctx.square = square }
                return ctx
            }
            
            Always(to: .alive).when { $0.isAlive }
        }
    }
}

// MARK: Sugar extensions

// These allow implicit member expressions for PieceEvent cases
// with associated values. E.g. `.sync` instead of the normally-
// required `PieceEvent.sync`.

extension Map where In == String?, Out == PieceEvent {
    static var sync: Map<In, Out> { .init(transform: Out.sync) }
}

extension Map where In == String, Out == PieceEvent {
    static var moveTo: Map<In, Out> { .init(transform: Out.moveTo) }
}
