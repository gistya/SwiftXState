import Testing
import Foundation
@testable import SwiftXState

/// A parent stand-in that records the events its children enqueue.
private final class RecordingParent: ActorParentRef, @unchecked Sendable {
    let system: ActorSystem
    private let onEvent: @Sendable (String) -> Void
    init(system: ActorSystem, onEvent: @escaping @Sendable (String) -> Void) {
        self.system = system
        self.onEvent = onEvent
    }
    var actorSystem: ActorSystem { system }
    func enqueueFromChild(_ event: any Eventable) async { onEvent(event.type) }
    func inspectSpawnedChild(_ child: any ChildActor, machineId: String?) async {}
}

@Suite("LogicChildActor<CallbackLogic> parity with CallbackChildRef")
struct CallbackLogicTests {

    private func makeChild(
        _ callback: CallbackActorLogic,
        parent: (any ActorParentRef)? = nil,
        system: ActorSystem
    ) -> LogicChildActor<CallbackLogic> {
        let actor = Actor(
            CallbackLogic(callback: callback, system: system),
            id: "cb", parent: parent, system: system
        )
        return LogicChildActor(actor: actor, id: "cb", systemId: nil, input: nil, inspectable: true)
    }

    @Test("receive → sendToParent round-trips, ordered")
    func receiveSendToParent() async {
        let system = ActorSystem()
        let gotPong = TestSignal()
        let parent = RecordingParent(system: system) { if $0 == "PONG" { gotPong.fire() } }
        let callback = CallbackActorLogic { scope in
            scope.receive { event in
                if event.type == "PING" { scope.sendToParent(Event("PONG")) }
            }
            return nil
        }
        let child = makeChild(callback, parent: parent, system: system)
        await child.start()
        await child.send(Event("PING"))
        #expect(await gotPong.wait())
    }

    @Test("emit → on() listener")
    func emitToOn() async {
        let system = ActorSystem()
        let armed = TestSignal()
        let callback = CallbackActorLogic { scope in
            scope.receive { event in
                if event.type == "ARM" { scope.emit(EmittedEvent("armed")) }
            }
            return nil
        }
        let child = makeChild(callback, system: system)
        await child.start()
        _ = await child.on("armed") { _ in armed.fire() }
        await child.send(Event("ARM"))
        #expect(await armed.wait())
    }

    @Test("stop runs the dispose and reports .stopped")
    func stopDispose() async {
        let system = ActorSystem()
        let disposed = TestSignal()
        let callback = CallbackActorLogic { _ in
            { disposed.fire() }
        }
        let child = makeChild(callback, system: system)
        await child.start()
        #expect(child.status == .active)
        await child.stop()
        #expect(await disposed.wait())
        #expect(child.status == .stopped)
    }
}
