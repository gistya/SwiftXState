import Foundation
import SwiftXState

enum ForfeitsCastlingGuard: GuardSpec {
    struct Params: GuardParamValues, Equatable, Codable {
        let side: ChessCastlingSide
    }

    static let name = "forfeitsCastling"
}

enum ChessCastlingMachine {
    static func region() -> StateNodeConfig<ChessContext> {
        StateNodeConfig(
            type: .parallel,
            states: [
                "whiteKingside": side(.whiteKingside),
                "whiteQueenside": side(.whiteQueenside),
                "blackKingside": side(.blackKingside),
                "blackQueenside": side(.blackQueenside),
            ]
        )
    }

    private static func side(_ side: ChessCastlingSide) -> StateNodeConfig<ChessContext> {
        StateNodeConfig(
            initial: "available",
            states: [
                "available": StateNodeConfig(on: [
                    "TAP.*": .single(TransitionConfig(
                        target: "forfeited",
                        guard: guardRef(ForfeitsCastlingGuard.self, params: .init(side: side))
                    )),
                    ChessEvent.newGame.type: .to("available"),
                ]),
                "forfeited": StateNodeConfig(on: [
                    ChessEvent.newGame.type: .to("available"),
                ]),
            ]
        )
    }

    static func registerGuards(
        into setup: MachineSetup<ChessContext>
    ) -> MachineSetup<ChessContext> {
        setup.registerGuard(ForfeitsCastlingGuard.self) { args, params in
            guard let move = ChessRules.pendingMove(from: args) else { return false }
            switch params.side {
            case .whiteKingside:
                return ChessRules.forfeitsWhiteKingside(move)
            case .whiteQueenside:
                return ChessRules.forfeitsWhiteQueenside(move)
            case .blackKingside:
                return ChessRules.forfeitsBlackKingside(move)
            case .blackQueenside:
                return ChessRules.forfeitsBlackQueenside(move)
            }
        }
    }
}