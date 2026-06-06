import Foundation
import SwiftXState

struct PieceContext: Sendable, Equatable, Codable {
    var pieceId: String
    var kind: PieceKind
    var color: PieceColor
    var square: String?

    var isAlive: Bool { square != nil }
}

enum PieceEvent: Eventable, Equatable, Sendable {
    case moveTo(square: String)
    case captured
    case sync(square: String?)

    var type: String {
        switch self {
        case let .moveTo(square): return "MOVE_TO.\(square)"
        case .captured: return "CAPTURED"
        case let .sync(square):
            if let square { return "SYNC.\(square)" }
            return "SYNC.off"
        }
    }

    static func parse(_ event: any Eventable) -> PieceEvent? {
        let type = event.type
        if type == "CAPTURED" { return .captured }
        if type.hasPrefix("MOVE_TO.") {
            return .moveTo(square: String(type.dropFirst(8)))
        }
        if type == "SYNC.off" { return .sync(square: nil) }
        if type.hasPrefix("SYNC.") {
            return .sync(square: String(type.dropFirst(5)))
        }
        return nil
    }
}

enum PieceActorMachine {
    static let id = "piece"

    static let machine: StateMachine<PieceContext> = createMachine(
        MachineConfig(
            id: id,
            initial: "boot",
            context: PieceContext(pieceId: "wPa2", kind: .pawn, color: .white, square: nil),
            states: [
                "boot": StateNodeConfig(
                    always: [
                        TransitionConfig(target: "alive", guard: .named("isAlive")),
                        TransitionConfig(target: "captured"),
                    ]
                ),
                "alive": StateNodeConfig(
                    on: [
                        "MOVE_TO.*": .single(TransitionConfig(actions: [assign { ctx, args in
                            if case let .moveTo(square) = PieceEvent.parse(args.event) {
                                ctx.square = square
                            }
                        }])),
                        "CAPTURED": .single(
                            TransitionConfig(
                                target: "captured",
                                actions: [assign { ctx, _ in ctx.square = nil }]
                            )
                        ),
                        "SYNC.*": .single(TransitionConfig(actions: [assign { ctx, args in
                            applySync(&ctx, args: args)
                        }])),
                        "SYNC.off": .single(TransitionConfig(actions: [assign { ctx, args in
                            applySync(&ctx, args: args)
                        }])),
                    ],
                    always: [
                        TransitionConfig(target: "captured", guard: .named("isDead")),
                    ]
                ),
                "captured": StateNodeConfig(
                    on: [
                        "SYNC.*": .single(
                            TransitionConfig(
                                target: "alive",
                                actions: [assign { ctx, args in
                                    applySync(&ctx, args: args)
                                }]
                            )
                        ),
                        "SYNC.off": .single(TransitionConfig(actions: [assign { ctx, args in
                            applySync(&ctx, args: args)
                        }])),
                    ],
                    always: [
                        TransitionConfig(target: "alive", guard: .named("isAlive")),
                    ]
                ),
            ]
        ),
        implementations: MachineImplementations.legacy(
            guards: [
                "isAlive": { args in args.context.square != nil },
                "isDead": { args in args.context.square == nil },
            ]
        )
    )

    private static func applySync(_ context: inout PieceContext, args: ActionArgs<PieceContext>) {
        guard case let .sync(square) = PieceEvent.parse(args.event) else { return }
        context.square = square
    }
}