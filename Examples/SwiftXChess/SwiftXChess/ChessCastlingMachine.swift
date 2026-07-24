import Foundation
import SwiftXState

// The castling parallel region is now folded directly into `ChessGameMachine` (see ChessMachine.swift):
// its four sides are built by `castlingSide(_:forfeits:)`, and the old named `ForfeitsCastlingGuard`
// (a `GuardSpec` registered via `setup(guards:)`) is replaced by an inline **event-aware** guard
// `.when { ctx, event in … ChessRules.pendingMove(ctx, to:) … }`. The per-side forfeit predicates
// (`ChessRules.forfeitsWhiteKingside`, …) live in ChessRules. This file is intentionally empty.
