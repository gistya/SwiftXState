import Foundation
import Testing
@testable import SwiftXChess
@testable import SwiftXState

@Suite("SwiftXChess replay integration")
struct SwiftXChessReplayIntegrationTests {
    @Test("ChessEvent parse and rules work outside the machine")
    func rulesHandleTapDirectly() {
        var context = ChessContext.initial()
        let event = ChessEvent.tap(Square(row: 1, col: 4))
        #expect(ChessEvent.parse(event) != nil)
        ChessRules.handleTap(&context, at: Square(row: 1, col: 4))
        #expect(context.selected == Square(row: 1, col: 4))
        ChessRules.handleTap(&context, at: Square(row: 3, col: 4))
        #expect(context.board[Square(row: 3, col: 4)]?.color == .white)
    }

    @Test("TAP events update chess context on live reactor")
    func tapUpdatesContext() {
        let reactor = createReactor(ChessMachineFactory.machine).start()
        #expect(reactor.snapshot.matches(ChessGameState.playing))
        #expect(reactor.snapshot.typed(as: ChessGameState.self).inState(.playing))

        let tapEvent = ChessEvent.tap(Square(row: 1, col: 4))
        let transitions = selectTransitions(event: tapEvent, snapshot: reactor.snapshot)
        #expect(!transitions.isEmpty)

        let (next, actions) = transition(
            ChessMachineFactory.machine,
            snapshot: reactor.snapshot,
            event: tapEvent
        )
        #expect(next.context.selected == Square(row: 1, col: 4))

        reactor.send(tapEvent)
        #expect(reactor.snapshot.context.selected == Square(row: 1, col: 4))

        reactor.send(ChessEvent.tap(Square(row: 3, col: 4)))
        #expect(reactor.snapshot.context.selected == nil)
        #expect(reactor.snapshot.context.board[Square(row: 3, col: 4)]?.color == .white)
        #expect(reactor.snapshot.context.turn == .black)
    }

    @Test("enter replay freezes session and scrub restores board positions")
    func replayScrubRestoresBoard() {
        let recorder = InspectionRecorder()
        let machine = ChessMachineFactory.machine
        let reactor = createReactor(
            machine,
            options: ReactorOptions(inspect: recorder.observe())
        ).start()

        // White pawn e2 -> e4
        reactor.send(ChessEvent.tap(Square(row: 1, col: 4)))
        reactor.send(ChessEvent.tap(Square(row: 3, col: 4)))

        let live = reactor.snapshot.context
        #expect(live.board[Square(row: 3, col: 4)]?.color == .white)
        #expect(live.turn == .black)

        guard let session = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }
        #expect(session.steps.count > 2)

        ChessReplayBridge.setPendingSession(session)
        reactor.send(ChessEvent.enterReplay)

        let replaying = reactor.snapshot.context
        #expect(replaying.replaySession != nil)
        #expect(replaying.isReplayMode)
        let lastStep = max(session.steps.count - 1, 0)
        #expect(replaying.replayStep == lastStep)

        let expectedEnd = timeTravel(
            machine,
            context: ChessContext.initial(),
            session: session,
            toStep: lastStep
        )?.context
        #expect(replaying.board == expectedEnd?.board)

        reactor.send(ChessEvent.replayScrub(0))
        let atStart = reactor.snapshot.context
        #expect(atStart.replayStep == 0)
        let expectedStart = timeTravel(
            machine,
            context: ChessContext.initial(),
            session: session,
            toStep: 0
        )?.context
        #expect(atStart.board == expectedStart?.board)

        reactor.send(ChessEvent.replayScrub(0))
        let backToStart = reactor.snapshot.context
        #expect(backToStart.replayStep == 0)
        #expect(backToStart.board[Square(row: 1, col: 4)]?.kind == .pawn)
        #expect(backToStart.board[Square(row: 3, col: 4)] == nil)
    }

    @Test("snapshot context decodes to matching time-travel board")
    func snapshotDecodeMatchesTimeTravel() {
        let recorder = InspectionRecorder()
        let machine = ChessMachineFactory.machine
        let reactor = createReactor(
            machine,
            options: ReactorOptions(inspect: recorder.observe())
        ).start()

        reactor.send(ChessEvent.tap(Square(row: 1, col: 4)))
        reactor.send(ChessEvent.tap(Square(row: 3, col: 4)))

        guard let session = recorder.session(), session.steps.count > 2 else {
            Issue.record("Expected recorded session with moves")
            return
        }

        let step = 2
        let fromSnapshot = ChessReplayRestore.playableContext(from: session.steps[step].snapshotAfter)
        let fromTravel = timeTravel(
            machine,
            context: ChessContext.initial(),
            session: session,
            toStep: step
        )?.context

        #expect(fromSnapshot != nil)
        #expect(fromTravel != nil)
        #expect(fromSnapshot?.board == fromTravel?.board)
        #expect(fromSnapshot?.turn == fromTravel?.turn)
    }

    @Test("session-style replay gate and scrub path")
    func sessionStyleReplayFlow() {
        final class Gate: @unchecked Sendable {
            private var enabled = true
            private let lock = NSLock()
            func setEnabled(_ value: Bool) {
                lock.lock()
                enabled = value
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

        let recorder = InspectionRecorder()
        let gate = Gate()
        let reactor = createReactor(
            ChessMachineFactory.machine,
            options: ReactorOptions(inspect: gate.observe(recorder))
        ).start()

        reactor.send(ChessEvent.tap(Square(row: 1, col: 4)))
        reactor.send(ChessEvent.tap(Square(row: 3, col: 4)))
        reactor.send(ChessEvent.tap(Square(row: 6, col: 4)))
        reactor.send(ChessEvent.tap(Square(row: 4, col: 4)))

        guard let recorded = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }
        let stepCount = max(recorded.steps.count - 1, 0)

        gate.setEnabled(false)
        ChessReplayBridge.setPendingSession(recorded)
        reactor.send(ChessEvent.enterReplay)

        var snapshot = reactor.snapshot
        #expect(snapshot.context.replaySession?.steps.count == recorded.steps.count)
        #expect(snapshot.context.replayStep == stepCount)
        #expect(snapshot.context.board[Square(row: 4, col: 4)]?.color == .black)

        func scrub(to step: Int) {
            let clamped = min(max(step, 0), stepCount)
            guard clamped != snapshot.context.replayStep else { return }
            reactor.send(ChessEvent.replayScrub(clamped))
            snapshot = reactor.snapshot
        }

        scrub(to: 0)
        #expect(snapshot.context.replayStep == 0)
        #expect(snapshot.context.board[Square(row: 1, col: 4)]?.kind == .pawn)
        #expect(snapshot.context.board[Square(row: 3, col: 4)] == nil)

        scrub(to: stepCount)
        #expect(snapshot.context.replayStep == stepCount)
        #expect(snapshot.context.board[Square(row: 4, col: 4)]?.color == .black)

        gate.setEnabled(true)
        reactor.send(ChessEvent.exitReplay)
        #expect(reactor.snapshot.context.replaySession == nil)
    }

    @Test("verify replay matches recorded snapshots")
    func verifyRecordedGame() {
        let recorder = InspectionRecorder()
        let machine = ChessMachineFactory.machine
        let reactor = createReactor(
            machine,
            options: ReactorOptions(inspect: recorder.observe())
        ).start()

        reactor.send(ChessEvent.tap(Square(row: 1, col: 4)))
        reactor.send(ChessEvent.tap(Square(row: 3, col: 4)))

        guard let session = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }

        let results = verifyReplay(machine, context: ChessContext.initial(), session: session)
        let failures = results.filter { !$0.matches }
        #expect(failures.isEmpty, "Replay mismatch at steps: \(failures.map(\.stepIndex))")
    }
}
