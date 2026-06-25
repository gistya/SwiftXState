#if canImport(Darwin)
import Testing
import Foundation
@testable import SwiftXState

/// Records which thread its `step` ran on — a deterministic probe of the actor's executor.
private struct ThreadProbeLogic: ActorLogic {
    struct State: Sendable, Equatable { var ranOnMain: Bool? = nil }
    func initialState(input: SendableValue?) -> State { State() }
    func step(_ snapshot: State, on event: any Eventable) -> State {
        var next = snapshot
        next.ranOnMain = Thread.isMainThread
        return next
    }
    func status(of snapshot: State) -> SnapshotStatus { .active }
}

@Suite("LogicActor custom executor")
struct LogicActorExecutorTests {

    @Test("useMainExecutor runs the actor on the main thread")
    func mainExecutor() async {
        let actor = await LogicActor(ThreadProbeLogic(), options: ActorOptions(useMainExecutor: true)).start()
        await actor.send(Event("X"))
        #expect(await actor.snapshot.ranOnMain == true)
    }

    @Test("default executor runs off the main thread")
    func dedicatedExecutor() async {
        let actor = await LogicActor(ThreadProbeLogic()).start()
        await actor.send(Event("X"))
        #expect(await actor.snapshot.ranOnMain == false)
    }
}
#endif
