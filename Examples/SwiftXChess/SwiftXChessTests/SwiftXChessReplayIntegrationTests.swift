import Foundation
import Synchronization
import Testing
@testable import SwiftXChess
@testable import SwiftXState

@Suite("SwiftXChess replay integration")
struct SwiftXChessReplayIntegrationTests {
    @Test("Chess rules work outside the machine")
    func rulesHandleTapDirectly() {
        var context = ChessContext.initial()
        ChessRules.handleTap(&context, at: Square(row: 1, col: 4))
        #expect(context.selected == Square(row: 1, col: 4))
        ChessRules.handleTap(&context, at: Square(row: 3, col: 4))
        #expect(context.board[Square(row: 3, col: 4)]?.color == .white)
    }

    @Test("TAP events update chess context on live actor")
    func tapUpdatesContext() async {
        let actor = await createActor(ChessGameMachine.resolved).start()
        var snapshot = await actor.snapshot
        #expect(snapshot.matches("game.playing"))

        let tapEvent = ChessEvent.tap(Square(row: 1, col: 4))
        let transitions = selectTransitions(event: tapEvent.event, snapshot: snapshot)
        #expect(!transitions.isEmpty)

        let (next, _) = transition(
            ChessGameMachine.resolved,
            snapshot: snapshot,
            event: tapEvent.event
        )
        #expect(next.context.selected == Square(row: 1, col: 4))

        await actor.send(tapEvent.event)
        snapshot = await actor.snapshot
        #expect(snapshot.context.selected == Square(row: 1, col: 4))

        await actor.send(ChessEvent.tap(Square(row: 3, col: 4)).event)
        snapshot = await actor.snapshot
        #expect(snapshot.context.selected == nil)
        #expect(snapshot.context.board[Square(row: 3, col: 4)]?.color == .white)
        #expect(snapshot.context.turn == .black)
    }

    @Test("enter replay freezes session and scrub restores board positions")
    func replayScrubRestoresBoard() async {
        let recorder = InspectionRecorder()
        let machine = ChessGameMachine.resolved
        let actor = await createActor(
            machine,
            options: ActorOptions(inspect: recorder.observe())
        ).start()

        // White pawn e2 -> e4
        await actor.send(ChessEvent.tap(Square(row: 1, col: 4)).event)
        await actor.send(ChessEvent.tap(Square(row: 3, col: 4)).event)

        let live = await actor.snapshot.context
        #expect(live.board[Square(row: 3, col: 4)]?.color == .white)
        #expect(live.turn == .black)

        guard let session = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }
        #expect(session.steps.count > 2)

        ChessReplayBridge.setPendingSession(session)
        await actor.send(ChessEvent.enterReplay.event)

        let replaying = await actor.snapshot.context
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

        await actor.send(ChessEvent.replayScrub(0).event)
        let atStart = await actor.snapshot.context
        #expect(atStart.replayStep == 0)
        let expectedStart = timeTravel(
            machine,
            context: ChessContext.initial(),
            session: session,
            toStep: 0
        )?.context
        #expect(atStart.board == expectedStart?.board)

        await actor.send(ChessEvent.replayScrub(0).event)
        let backToStart = await actor.snapshot.context
        #expect(backToStart.replayStep == 0)
        #expect(backToStart.board[Square(row: 1, col: 4)]?.kind == .pawn)
        #expect(backToStart.board[Square(row: 3, col: 4)] == nil)
    }

    @Test("snapshot context decodes to matching time-travel board")
    func snapshotDecodeMatchesTimeTravel() async {
        let recorder = InspectionRecorder()
        let machine = ChessGameMachine.resolved
        let actor = await createActor(
            machine,
            options: ActorOptions(inspect: recorder.observe())
        ).start()

        await actor.send(ChessEvent.tap(Square(row: 1, col: 4)).event)
        await actor.send(ChessEvent.tap(Square(row: 3, col: 4)).event)

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
    func sessionStyleReplayFlow() async {
        final class Gate: @unchecked Sendable {
            private var enabled = true
            private let lock = Mutex(false)
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
        let actor = await createActor(
            ChessGameMachine.resolved,
            options: ActorOptions(inspect: gate.observe(recorder))
        ).start()

        await actor.send(ChessEvent.tap(Square(row: 1, col: 4)).event)
        await actor.send(ChessEvent.tap(Square(row: 3, col: 4)).event)
        await actor.send(ChessEvent.tap(Square(row: 6, col: 4)).event)
        await actor.send(ChessEvent.tap(Square(row: 4, col: 4)).event)

        guard let recorded = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }
        let stepCount = max(recorded.steps.count - 1, 0)

        gate.setEnabled(false)
        ChessReplayBridge.setPendingSession(recorded)
        await actor.send(ChessEvent.enterReplay.event)

        var snapshot = await actor.snapshot
        #expect(snapshot.context.replaySession?.steps.count == recorded.steps.count)
        #expect(snapshot.context.replayStep == stepCount)
        #expect(snapshot.context.board[Square(row: 4, col: 4)]?.color == .black)

        func scrub(to step: Int) async {
            let clamped = min(max(step, 0), stepCount)
            guard clamped != snapshot.context.replayStep else { return }
            await actor.send(ChessEvent.replayScrub(clamped).event)
            snapshot = await actor.snapshot
        }

        await scrub(to: 0)
        #expect(snapshot.context.replayStep == 0)
        #expect(snapshot.context.board[Square(row: 1, col: 4)]?.kind == .pawn)
        #expect(snapshot.context.board[Square(row: 3, col: 4)] == nil)

        await scrub(to: stepCount)
        #expect(snapshot.context.replayStep == stepCount)
        #expect(snapshot.context.board[Square(row: 4, col: 4)]?.color == .black)

        gate.setEnabled(true)
        await actor.send(ChessEvent.exitReplay.event)
        let final = await actor.snapshot
        #expect(final.context.replaySession == nil)
    }

    @Test("verify replay matches recorded snapshots")
    func verifyRecordedGame() async {
        let recorder = InspectionRecorder()
        let machine = ChessGameMachine.resolved
        let actor = await createActor(
            machine,
            options: ActorOptions(inspect: recorder.observe())
        ).start()

        await actor.send(ChessEvent.tap(Square(row: 1, col: 4)).event)
        await actor.send(ChessEvent.tap(Square(row: 3, col: 4)).event)

        guard let session = recorder.session() else {
            Issue.record("Expected recorded session")
            return
        }

        let results = verifyReplay(machine, context: ChessContext.initial(), session: session)
        let failures = results.filter { !$0.matches }
        #expect(failures.isEmpty, "Replay mismatch at steps: \(failures.map(\.stepIndex))")
    }
}
