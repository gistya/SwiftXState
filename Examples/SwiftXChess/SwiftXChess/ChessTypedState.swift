import Foundation
import SwiftXState

/// Typed brands for the `game` region of the chess machine (`game.*`).
enum ChessGameState: String, StateID, Sendable, Equatable, CaseIterable {
    case playing
    case gameOver
    case replaying

    var statePath: String { "game.\(rawValue)" }

    var displayName: String {
        switch self {
        case .playing: return "Playing"
        case .gameOver: return "Game over"
        case .replaying: return "Replaying"
        }
    }
}

extension TypedSnapshot where Context == ChessContext, Brand == ChessGameState {
    /// The active `game` region state, if the runtime value matches a known brand.
    var gamePhase: ChessGameState? {
        ChessGameState.allCases.first { inState($0) }
    }
}

// MARK: - Castling parallel region

/// Brand for the root `castling` parallel region.
enum ChessCastlingRegion: StateID, Sendable {
    case region

    var statePath: String { "castling" }
}

/// One of the four parallel castling-right tracks (`castling.whiteKingside`, …).
enum ChessCastlingSide: String, StateID, Sendable, Equatable, Codable, CaseIterable {
    case whiteKingside
    case whiteQueenside
    case blackKingside
    case blackQueenside

    var statePath: String { "castling.\(rawValue)" }

    var shortLabel: String {
        switch self {
        case .whiteKingside: return "W-K"
        case .whiteQueenside: return "W-Q"
        case .blackKingside: return "B-K"
        case .blackQueenside: return "B-Q"
        }
    }
}

enum ChessCastlingAvailability: String, StateID, Sendable, Equatable, CaseIterable {
    case available
    case forfeited

    var displayName: String {
        switch self {
        case .available: return "Available"
        case .forfeited: return "Forfeited"
        }
    }
}

/// Fully qualified castling side state (`castling.whiteKingside.available`, …).
struct ChessCastlingSideState: StateID, Sendable, Equatable, Hashable {
    let side: ChessCastlingSide
    let availability: ChessCastlingAvailability

    var statePath: String { "\(side.statePath).\(availability.rawValue)" }

    static var initial: [ChessCastlingSideState] {
        ChessCastlingSide.allCases.map {
            ChessCastlingSideState(side: $0, availability: .available)
        }
    }
}

extension TypedSnapshot where Context == ChessContext, Brand == ChessCastlingRegion {
    func availability(for side: ChessCastlingSide) -> ChessCastlingAvailability? {
        ChessCastlingAvailability.allCases.first {
            matches(ChessCastlingSideState(side: side, availability: $0))
        }
    }

    func inSideState(_ state: ChessCastlingSideState) -> Bool {
        matches(state)
    }

    /// Board-level castling rights derived from parallel region child states.
    var castlingRights: CastlingRights {
        CastlingRights(
            whiteKingside: availability(for: .whiteKingside) == .available,
            whiteQueenside: availability(for: .whiteQueenside) == .available,
            blackKingside: availability(for: .blackKingside) == .available,
            blackQueenside: availability(for: .blackQueenside) == .available
        )
    }
}

// MARK: - View state (mapState)

/// UI-facing state derived from the machine snapshot via `mapState`.
struct ChessViewState: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case playing
        case replaying
        case gameOver
    }

    var phase: Phase
    var statusLine: String
    var isBoardInteractive: Bool

    var isReplaying: Bool { phase == .replaying }
}

extension ChessViewState.Phase {
    var displayName: String {
        switch self {
        case .playing: return "Playing"
        case .replaying: return "Replaying"
        case .gameOver: return "Game over"
        }
    }
}

enum ChessViewStateMapper {
    static let mapper = StateMap<ChessContext, ChessViewState>(
        states: [
            "game": StateMap(
                states: [
                    "playing": .mapped { snapshot in
                        ChessViewState(
                            phase: .playing,
                            statusLine: snapshot.context.statusLine,
                            isBoardInteractive: snapshot.context.outcome == nil
                        )
                    },
                    "replaying": .mapped { snapshot in
                        ChessViewState(
                            phase: .replaying,
                            statusLine: snapshot.context.statusLine,
                            isBoardInteractive: false
                        )
                    },
                    "gameOver": .mapped { snapshot in
                        ChessViewState(
                            phase: .gameOver,
                            statusLine: snapshot.context.statusLine,
                            isBoardInteractive: false
                        )
                    },
                ]
            ),
        ]
    )
}

extension CastlingRights {
    init(stateValue: StateValue) {
        func isAvailable(_ side: ChessCastlingSide) -> Bool {
            stateValue.matches(ChessCastlingSideState(side: side, availability: .available))
        }
        whiteKingside = isAvailable(.whiteKingside)
        whiteQueenside = isAvailable(.whiteQueenside)
        blackKingside = isAvailable(.blackKingside)
        blackQueenside = isAvailable(.blackQueenside)
    }
}