import Foundation
import SwiftXState

struct SquareContext: Sendable, Equatable, Hashable, Codable {
    var coord: String
    var occupantId: String?

    var isOccupied: Bool { occupantId != nil }
}

enum SquareState: String, StateIdentifying {
    case boot, empty, occupied
    static var _blank: SquareState { .boot }
}

/// Typed payload events — the old `OCCUPY.<id>` / `SYNC.<id>` / `SYNC.empty` type-string encoding and
/// the hand-written `parse(_:)` are gone; handlers read the payload off `args.event`.
enum SquareEvent: EventIdentifying {
    case occupy(pieceId: String)
    case clear
    case sync(occupantId: String?)

    static var _blank: SquareEvent { .clear }
}

/// A board square as a typed `StateMachine`: `boot` resolves to `empty`/`occupied` from its seeded
/// context, then tracks occupancy via events. Spawned per square by the GameWatcher (each seeded with
/// its own `coord`/`occupantId`).
struct SquareActorMachine: StateMachine {
    typealias Context = SquareContext
    typealias StateID = SquareState
    typealias EventID = SquareEvent

    static let id = "square"

    var context: SquareContext { SquareContext(coord: "a1", occupantId: nil) }

    var machine: some XStateMachine {
        State(.boot) {
            Always(to: .occupied).when { $0.isOccupied }
            Always(to: .empty)
        }
        .initial()

        State(.empty) {
            Transition(on: .occupy, to: .occupied).action { args, _ in
                var ctx = args.context
                if case let .occupy(pieceId)? = args.event { ctx.occupantId = pieceId }
                return ctx
            }
            
            Transition(on: .sync, to: .empty).action { args, _ in
                var ctx = args.context
                if case let .sync(occupantId)? = args.event { ctx.occupantId = occupantId }
                return ctx
            }
            
            Always(to: .occupied).when { $0.isOccupied }
        }

        State(.occupied) {
            Transition(on: .clear, to: .empty).action { ctx in
                var c = ctx; c.occupantId = nil; return c
            }
            
            Transition(on: .occupy, to: .occupied).action { args, _ in
                var ctx = args.context
                if case let .occupy(pieceId)? = args.event { ctx.occupantId = pieceId }
                return ctx
            }
            
            Transition(on: .sync, to: .occupied).action { args, _ in
                var ctx = args.context
                if case let .sync(occupantId)? = args.event { ctx.occupantId = occupantId }
                return ctx
            }
            
            Always(to: .empty).when { !$0.isOccupied }
        }
    }
}

// MARK: Sugar extensions

// These allow implicit member expressions for PieceEvent cases
// with associated values.

extension Map where In == String?, Out == SquareEvent {
    static var sync: Map<In, Out> { .init(transform: Out.sync) }
}

extension Map where In == String, Out == SquareEvent {
    static var occupy: Map<In, Out> { .init(transform: Out.occupy) }
}
