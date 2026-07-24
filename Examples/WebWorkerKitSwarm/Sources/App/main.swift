import JavaScriptKit
import JavaScriptEventLoop
import WebWorkerKit

// This same bundle is loaded three times: once on the page (main thread) and once inside
// each spawned Web Worker. `initialize()` wires the main↔worker message channel in every
// context; only the main context builds the interactive UI. In a worker, the actor system
// instead hosts the distributed actor it was spawned for.
JavaScriptEventLoop.installGlobalExecutor()
WebWorkerActorSystem.initialize()

if !WebWorkerActorSystem.thisProcessIsAWebWorker {
    MainActor.assumeIsolated { runControlRoom() }
}
