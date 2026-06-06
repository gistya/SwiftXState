import Foundation
import SwiftXState

struct SquareContext: Sendable, Equatable, Codable {
    var coord: String
    var occupantId: String?

    var isOccupied: Bool { occupantId != nil }
}

enum SquareEvent: Eventable, Equatable, Sendable {
    case occupy(pieceId: String)
    case clear
    case sync(occupantId: String?)

    var type: String {
        switch self {
        case let .occupy(pieceId): return "OCCUPY.\(pieceId)"
        case .clear: return "CLEAR"
        case let .sync(occupantId):
            if let occupantId { return "SYNC.\(occupantId)" }
            return "SYNC.empty"
        }
    }

    static func parse(_ event: any Eventable) -> SquareEvent? {
        let type = event.type
        if type == "CLEAR" { return .clear }
        if type.hasPrefix("OCCUPY.") {
            return .occupy(pieceId: String(type.dropFirst(7)))
        }
        if type == "SYNC.empty" { return .sync(occupantId: nil) }
        if type.hasPrefix("SYNC.") {
            return .sync(occupantId: String(type.dropFirst(5)))
        }
        return nil
    }
}

enum SquareActorMachine {
    static let id = "square"

    static let machine: StateMachine<SquareContext> = createMachine(
        MachineConfig(
            id: id,
            initial: "boot",
            context: SquareContext(coord: "a1", occupantId: nil),
            states: [
                "boot": StateNodeConfig(
                    always: [
                        TransitionConfig(target: "occupied", guard: .named("hasOccupant")),
                        TransitionConfig(target: "empty"),
                    ]
                ),
                "empty": StateNodeConfig(
                    on: [
                        "OCCUPY.*": .single(
                            TransitionConfig(
                                target: "occupied",
                                actions: [assign { ctx, args in
                                    if case let .occupy(pieceId) = SquareEvent.parse(args.event) {
                                        ctx.occupantId = pieceId
                                    }
                                }]
                            )
                        ),
                        "SYNC.*": .single(TransitionConfig(actions: [assign { ctx, args in
                            applySync(&ctx, args: args)
                        }])),
                        "SYNC.empty": .single(TransitionConfig(actions: [assign { ctx, args in
                            applySync(&ctx, args: args)
                        }])),
                    ],
                    always: [
                        TransitionConfig(target: "occupied", guard: .named("hasOccupant")),
                    ]
                ),
                "occupied": StateNodeConfig(
                    on: [
                        "CLEAR": .single(
                            TransitionConfig(
                                target: "empty",
                                actions: [assign { ctx, _ in ctx.occupantId = nil }]
                            )
                        ),
                        "OCCUPY.*": .single(TransitionConfig(actions: [assign { ctx, args in
                            if case let .occupy(pieceId) = SquareEvent.parse(args.event) {
                                ctx.occupantId = pieceId
                            }
                        }])),
                        "SYNC.*": .single(TransitionConfig(actions: [assign { ctx, args in
                            applySync(&ctx, args: args)
                        }])),
                        "SYNC.empty": .single(TransitionConfig(actions: [assign { ctx, args in
                            applySync(&ctx, args: args)
                        }])),
                    ],
                    always: [
                        TransitionConfig(target: "empty", guard: .named("isVacant")),
                    ]
                ),
            ]
        ),
        implementations: MachineImplementations.legacy(
            guards: [
                "hasOccupant": { args in args.context.occupantId != nil },
                "isVacant": { args in args.context.occupantId == nil },
            ]
        )
    )

    private static func applySync(_ context: inout SquareContext, args: ActionArgs<SquareContext>) {
        guard case let .sync(occupantId) = SquareEvent.parse(args.event) else { return }
        context.occupantId = occupantId
    }
}