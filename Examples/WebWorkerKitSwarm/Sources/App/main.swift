import Distributed
import JavaScriptKit
import JavaScriptEventLoop
import WebWorkerKit
import SwiftXStateDistributed

func log(_ s: String) {
    print(s)
    guard let doc = JSObject.global.document.object else { return }
    if let pre = doc.getElementById!("out").object {
        pre.textContent = .string((pre.textContent.string ?? "") + s + "\n")
    }
}

JavaScriptEventLoop.installGlobalExecutor()
WebWorkerActorSystem.initialize() // wires main ↔ worker message channel (runs in both contexts)

// This same bundle is loaded again inside each spawned worker; only the main JS context
// drives the demo. (In the worker, `initialize()` above set it up to host the actor.)
if !WebWorkerActorSystem.thisProcessIsAWebWorker {
    if let doc = JSObject.global.document.object, let pre = doc.createElement!("pre").object {
        pre.id = "out"
        pre.textContent = "booting…\n"
        if let body = doc.body.object { _ = body.appendChild!(pre) }
    }
    Task {
        do {
            log("spawning CounterWorker — a SwiftXState machine in its own Web Worker…")
            let worker = try CounterWorker.new()
            var r = try await worker.report()
            log("  initial: state=\(r.state) value=\(r.context.value)")
            for i in 1...7 {
                r = try await worker.send("INC")
                log("  INC #\(i) → value=\(r.context.value)")
            }
            r = try await worker.send("DEC");   log("  DEC   → value=\(r.context.value)")
            r = try await worker.send("RESET"); log("  RESET → value=\(r.context.value)")
            log("done — the machine stepped inside the worker; every event + report crossed as Codable.")
        } catch {
            log("error: \(error)")
        }
    }
}
