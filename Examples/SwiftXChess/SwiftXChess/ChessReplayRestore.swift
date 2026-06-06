import Foundation
import SwiftXState

/// Suppresses inspection recording during replay scrubbing so scrub events
/// are not appended to the live session (which would inflate the slider range).
final class ReplayRecordingGate: @unchecked Sendable {
    private var enabled = true
    private let lock = NSLock()

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        lock.unlock()
    }

    func observe(_ recorder: InspectionRecorder) -> @Sendable (InspectionEvent) -> Void {
        let record = recorder.observe()
        return { [self] event in
            lock.lock()
            let enabled = self.enabled
            lock.unlock()
            guard enabled else { return }
            record(event)
        }
    }
}

enum GameWatcherReplayRestore {
    static func playableContext(from snapshot: InspectionSnapshot) -> GameWatcherContext? {
        decodeContext(snapshot.context)
    }

    static func decodeContext(_ json: JSONValue) -> GameWatcherContext? {
        guard let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONDecoder().decode(GameWatcherContext.self, from: data)
    }

    static func apply(
        stepIndex: Int,
        recorded: RecordedStep,
        session: ReplaySession,
        to context: inout GameWatcherContext
    ) {
        if let restored = playableContext(from: recorded.snapshotAfter) {
            applyPlayableFields(from: restored, to: &context)
        } else if let traveled = timeTravel(
            GameWatcherMachine.make(),
            context: GameWatcherContext.initial(),
            session: session,
            toStep: stepIndex
        ) {
            applyPlayableFields(from: traveled.context, to: &context)
        }

        context.selected = nil
        context.replaySession = session
        context.replayStep = stepIndex
    }

    private static func applyPlayableFields(
        from restored: GameWatcherContext,
        to context: inout GameWatcherContext
    ) {
        context.board = restored.board
        context.turn = restored.turn
        context.moveHistory = restored.moveHistory
        context.outcome = restored.outcome
        context.castlingRights = restored.castlingRights
        context.pendingPromotion = restored.pendingPromotion
        context.occupants = restored.occupants
        context.lastSAN = restored.lastSAN
        context.plyCount = restored.plyCount
    }
}

enum ChessReplayRestore {
    /// Restores playable chess fields from a recorded inspection snapshot.
    static func playableContext(from snapshot: InspectionSnapshot) -> ChessContext? {
        decodeContext(snapshot.context)
    }

    static func decodeContext(_ json: JSONValue) -> ChessContext? {
        guard let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONDecoder().decode(ChessContext.self, from: data)
    }

    static func apply(
        stepIndex: Int,
        recorded: RecordedStep,
        session: ReplaySession,
        to context: inout ChessContext
    ) {
        if let restored = playableContext(from: recorded.snapshotAfter) {
            context.board = restored.board
            context.turn = restored.turn
            context.moveHistory = restored.moveHistory
            context.outcome = restored.outcome
            context.castlingRights = restored.castlingRights
            context.pendingPromotion = restored.pendingPromotion
        } else if let traveled = timeTravel(
            ChessMachineFactory.machine,
            context: ChessContext.initial(),
            session: session,
            toStep: stepIndex
        ) {
            context.board = traveled.context.board
            context.turn = traveled.context.turn
            context.moveHistory = traveled.context.moveHistory
            context.outcome = traveled.context.outcome
            context.castlingRights = traveled.context.castlingRights
            context.pendingPromotion = traveled.context.pendingPromotion
        }

        context.selected = nil
        context.replaySession = session
        context.replayStep = stepIndex
    }
}