import Testing
@testable import SwiftXState
import SwiftXStateInspect
@testable import SwiftXChess
import SwiftXChessOpenings
import Foundation

@Suite("Game watcher orchestrator")
struct GameWatcherTests {
    @Test("distributed chess move wire events stay inspector-safe")
    func distributedChessMoveWireEvents() async throws {
        let collector = InspectionCollector()
        let converter = StatelyWireConverter(machineDefinitions: [
            try InspectMachineRegistration(
                machineId: GameWatcherMachine.id,
                definitionJSON: GameWatcherMachine.inspectorSummaryMachine().definitionJSON()
            ),
            try InspectMachineRegistration(
                machineId: OpeningMoveTreeMachine.id,
                definitionJSON: OpeningMoveTreeMachine.inspectorSummaryMachine().definitionJSON(),
                wireStateValue: OpeningMoveTreeMachine.inspectorWireState
            ),
        ])

        let watcher = await createActor(
            GameWatcherMachine.make(),
            options: ActorOptions(inspect: collector.observe())
        ).start()
        let treeSession = try await OpeningTreeSession()
        await treeSession.attachInspect(collector.observe())
        try? await Task.sleep(for: .milliseconds(100))

        let treeRegistration = collector.recordedEvents().filter {
            $0.kind == .actor && $0.actor.machineId == OpeningMoveTreeMachine.id
        }
        #expect(treeRegistration.count == 1)

        collector.reset()

        await watcher.send(ChessEvent.tap(Square(row: 1, col: 4)).event)
        try? await Task.sleep(for: .milliseconds(30))
        await watcher.send(ChessEvent.tap(Square(row: 3, col: 4)).event)
        try? await Task.sleep(for: .milliseconds(50))

        let san = await watcher.snapshot.context.lastSAN
        #expect(san == "e4")
        await treeSession.sendAndWait(san: san!)
        try? await Task.sleep(for: .milliseconds(30))

        let events = collector.recordedEvents()
        #expect(!events.isEmpty)

        for event in events {
            let sessionId = event.actor.sessionId
            #expect(!sessionId.hasPrefix("square."))
            #expect(!sessionId.hasPrefix("piece."))

            guard let wireData = converter.wireData(for: event),
                  let object = try JSONSerialization.jsonObject(with: wireData) as? [String: Any] else {
                continue
            }

            if event.actor.machineId == GameWatcherMachine.id,
               let snapshotObject = object["snapshot"] as? [String: Any],
               let children = snapshotObject["children"] as? [String: Any] {
                #expect(Set(children.keys) == ["board-pieces", "board-occupancy"])
            }

            if event.actor.machineId == OpeningMoveTreeMachine.id {
                #expect(object["_transitions"] == nil)
                if let snapshotObject = object["snapshot"] as? [String: Any] {
                    #expect(snapshotObject["value"] as? String == OpeningMoveTreeMachine.inspectorWireState)
                }
            }
        }
    }

    @Test("exports game-watcher definition JSON")
    func gameWatcherDefinition() throws {
        let json = try GameWatcherMachine.make().definitionJSON()
        let path = URL(fileURLWithPath: "game-watcher-definition.json")
        try json.write(to: path, atomically: true, encoding: .utf8)
        #expect(json.contains("\"id\":\"game-watcher\""))
        #expect(json.contains("\"target\":\"#game-watcher.boot\""))
        #expect(!json.contains("\"target\":\"boot\""))
        #expect(json.contains("xstate.spawnChild"))
    }

    @Test("exports game-watcher inspector summary without board spawns")
    func gameWatcherInspectorDefinition() throws {
        let json = try GameWatcherMachine.inspectorSummaryMachine().definitionJSON()
        #expect(json.contains("\"id\":\"game-watcher\""))
        #expect(!json.contains("xstate.spawnChild"))
        #expect(json.contains("game.active.turn.idle"))
    }

    @Test("board children do not emit inspection events")
    func boardChildrenHiddenFromInspect() async {
        let collector = InspectionCollector()
        let actor = await createActor(
            GameWatcherMachine.make(),
            options: ActorOptions(inspect: collector.observe())
        ).start()
        try? await Task.sleep(for: .milliseconds(150))

        await actor.send(ChessEvent.tap(Square(row: 1, col: 3)).event)
        try? await Task.sleep(for: .milliseconds(30))
        await actor.send(ChessEvent.tap(Square(row: 3, col: 3)).event)
        try? await Task.sleep(for: .milliseconds(80))

        let boardEvents = collector.recordedEvents().filter { event in
            let id = event.actor.sessionId
            return id.hasPrefix("square.") || id.hasPrefix("piece.")
        }
        #expect(boardEvents.isEmpty)

        let watcherEvents = collector.recordedEvents().filter { $0.actor.machineId == GameWatcherMachine.id }
        #expect(!watcherEvents.isEmpty)
    }

    @Test("spawns square and piece children on boot")
    func spawnsChildren() async {
        let actor = await createActor(GameWatcherMachine.make()).start()
        try? await Task.sleep(for: .milliseconds(100))

        let snapshot = await actor.snapshot
        #expect(snapshot.matches("game.active.turn.idle"))
        #expect(snapshot.children.count == 98) // 64 squares + 32 pieces + 2 board views
        #expect(snapshot.children[BoardInspectorMachine.childId(.occupancy)]?.status == .active)
        #expect(snapshot.children[BoardInspectorMachine.childId(.pieces)]?.status == .active)
        #expect(snapshot.children["square.e4"]?.status == .active)
        #expect(snapshot.children["piece.wPe2"]?.status == .active)
    }

    @Test("TAP e2 then e4 moves pawn and updates distributed actors")
    func tapMoveUpdatesActors() async {
        let actor = await createActor(GameWatcherMachine.make()).start()
        try? await Task.sleep(for: .milliseconds(100))

        await actor.send(ChessEvent.tap(Square(row: 1, col: 4)).event)
        try? await Task.sleep(for: .milliseconds(30))
        var snapshot = await actor.snapshot
        #expect(snapshot.context.selected == Square(row: 1, col: 4))
        #expect(snapshot.matches("game.active.turn.selecting"))

        await actor.send(ChessEvent.tap(Square(row: 3, col: 4)).event)
        try? await Task.sleep(for: .milliseconds(50))

        snapshot = await actor.snapshot
        #expect(snapshot.context.moveHistory.count == 1)
        #expect(snapshot.context.lastSAN == "e4")
        #expect(snapshot.context.turn == .black)

        let e2 = await squareContext(actor, coord: "e2")
        let e4 = await squareContext(actor, coord: "e4")
        let pawn = await pieceContext(actor, id: "wPe2")

        #expect(e2?.occupantId == nil)
        #expect(e4?.occupantId == "wPe2")
        #expect(pawn?.square == "e4")
        #expect(await squareState(actor, coord: "e2") == "empty")
        #expect(await squareState(actor, coord: "e4") == "occupied")
    }

    @Test("inspector snapshots expose board facade but not square or piece actors")
    func inspectorSnapshotsExposeBoardFacadeOnly() async {
        let collector = InspectionCollector()
        let actor = await createActor(
            GameWatcherMachine.make(),
            options: ActorOptions(inspect: collector.observe())
        ).start()
        try? await Task.sleep(for: .milliseconds(100))

        await actor.send(ChessEvent.tap(Square(row: 1, col: 4)).event)
        try? await Task.sleep(for: .milliseconds(30))
        await actor.send(ChessEvent.tap(Square(row: 3, col: 4)).event)
        try? await Task.sleep(for: .milliseconds(80))

        let watcherSnapshots = collector.recordedEvents().filter {
            $0.actor.machineId == GameWatcherMachine.id && $0.snapshot != nil
        }
        #expect(!watcherSnapshots.isEmpty)

        let inspectorActor = collector.recordedEvents().contains {
            $0.kind == .actor && $0.actor.machineId == BoardInspectorMachine.id(.occupancy)
        }
        #expect(inspectorActor)

        let latest = watcherSnapshots.last?.snapshot
        #expect(latest?.childCount == 2) // both board views; squares/pieces are off-inspector
        if case let .object(children) = latest?.children {
            #expect(Set(children.keys) == [BoardInspectorMachine.childId(.occupancy), BoardInspectorMachine.childId(.pieces)])
        }
    }

    @Test("combined inspect wiring records steps for replay UI")
    func combinedInspectRecordsSteps() async {
        let recorder = InspectionRecorder()
        let gate = ReplayRecordingGate()
        let inspect: @Sendable (InspectionEvent) -> Void = { event in
            gate.observe(recorder)(event)
        }
        let actor = await createActor(
            GameWatcherMachine.make(),
            options: ActorOptions(inspect: inspect)
        ).start()
        try? await Task.sleep(for: .milliseconds(100))

        await actor.send(ChessEvent.tap(Square(row: 1, col: 4)).event)
        try? await Task.sleep(for: .milliseconds(30))
        await actor.send(ChessEvent.tap(Square(row: 3, col: 4)).event)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(recorder.recordedSteps().count > 1)
    }

    @Test("inspection root id stays game-watcher after board spawns")
    func inspectionRootIdIsWatcher() async {
        let collector = InspectionCollector()
        let actor = await createActor(
            GameWatcherMachine.make(),
            options: ActorOptions(inspect: collector.observe())
        ).start()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(actor.actorSystem.rootSessionId == GameWatcherMachine.id)
        let roots = Set(collector.recordedEvents().map(\.rootId))
        #expect(roots == [GameWatcherMachine.id])
    }

    @Test("replay scrub restores game-watcher board from recorded inspection")
    func replayScrubRestoresBoard() async {
        let recorder = InspectionRecorder()
        let actor = await createActor(
            GameWatcherMachine.make(),
            options: ActorOptions(inspect: recorder.observe())
        ).start()
        try? await Task.sleep(for: .milliseconds(100))

        await actor.send(ChessEvent.tap(Square(row: 1, col: 4)).event)
        try? await Task.sleep(for: .milliseconds(30))
        await actor.send(ChessEvent.tap(Square(row: 3, col: 4)).event)
        try? await Task.sleep(for: .milliseconds(150))

        guard let session = recorder.session(), session.steps.count > 1 else {
            Issue.record("Expected recorded inspection session with moves")
            return
        }

        ChessReplayBridge.setPendingSession(session)
        await actor.send(ChessEvent.enterReplay.event)
        try? await Task.sleep(for: .milliseconds(20))

        let lastStep = max(session.steps.count - 1, 0)
        var snapshot = await actor.snapshot
        #expect(snapshot.context.isReplayMode)
        #expect(snapshot.context.replayStep == lastStep)
        #expect(snapshot.context.board[Square(row: 3, col: 4)]?.color == .white)
        #expect(snapshot.context.lastSAN == "e4")

        await actor.send(ChessEvent.replayScrub(0).event)
        try? await Task.sleep(for: .milliseconds(20))
        snapshot = await actor.snapshot
        #expect(snapshot.context.replayStep == 0)
        #expect(snapshot.context.board[Square(row: 3, col: 4)] == nil)
    }

    @Test("opening line e4 e5 Nf3 produces expected SAN sequence")
    func openingLine() async {
        let actor = await createActor(GameWatcherMachine.make()).start()
        try? await Task.sleep(for: .milliseconds(100))

        await tap(actor, row: 1, col: 4)
        await tap(actor, row: 3, col: 4)
        await tap(actor, row: 6, col: 4)
        await tap(actor, row: 4, col: 4)
        await tap(actor, row: 0, col: 6)
        await tap(actor, row: 2, col: 5)
        try? await Task.sleep(for: .milliseconds(80))

        let snapshot = await actor.snapshot
        #expect(snapshot.context.moveHistory.count == 3)
        #expect(snapshot.context.lastSAN == "Nf3")
        #expect(snapshot.context.plyCount == 3)
    }

    private func tap(_ actor: Actor<MachineLogic<GameWatcherContext>>, row: Int, col: Int) async {
        await actor.send(ChessEvent.tap(Square(row: row, col: col)).event)
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func squareContext(_ actor: Actor<MachineLogic<GameWatcherContext>>, coord: String) async -> SquareContext? {
        guard let child = await actor.childActor(id: BoardActorIds.square(coord)) as? MachineChildRef<SquareContext> else {
            return nil
        }
        return await child.actor.snapshot.context
    }

    private func pieceContext(_ actor: Actor<MachineLogic<GameWatcherContext>>, id: String) async -> PieceContext? {
        guard let child = await actor.childActor(id: BoardActorIds.piece(id: id)) as? MachineChildRef<PieceContext> else {
            return nil
        }
        return await child.actor.snapshot.context
    }

    private func squareState(_ actor: Actor<MachineLogic<GameWatcherContext>>, coord: String) async -> String? {
        guard let child = await actor.childActor(id: BoardActorIds.square(coord)) as? MachineChildRef<SquareContext> else {
            return nil
        }
        return await child.actor.snapshot.value.description
    }
}
