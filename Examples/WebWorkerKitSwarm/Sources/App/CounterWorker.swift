import Distributed
import WebWorkerKit
import SwiftXStateDistributed

// A SwiftXState machine that lives inside its own Web Worker, addressed as a
// `distributed actor`. Callers on the main thread invoke `send`/`report`; the arguments
// and the `MachineReport` return value cross the worker boundary as Codable. The machine
// itself (the non-Codable `MachineHost`) never leaves the worker.
distributed actor CounterWorker: WebWorker {
    typealias ActorSystem = WebWorkerActorSystem

    // A dedicated classic-worker entry that boots this same app. It must be a *classic*
    // worker (not `type:module`) because WebWorkerKit detects the worker context via
    // `importScripts`, which only exists in classic workers; the entry then dynamic-
    // imports the PackageToJS ES-module bundle (which `nil`/defaultScriptPath can't do —
    // that resolves to the `.wasm` path under WASI).
    static let scriptPath: String? = "./worker.js"
    static let isModule = false

    // Worker-local machine state — created when the actor is instantiated inside the worker.
    private let host = MachineHost(makeCounter())

    // `WebWorker` requires `Hashable`; distributed actors are identified by their `id`.
    nonisolated static func == (lhs: CounterWorker, rhs: CounterWorker) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Send one event to the worker-hosted machine and get the new report back.
    distributed func send(_ event: String) -> MachineReport<CounterContext> { host.send(event) }

    /// The machine's current report, without advancing.
    distributed func report() -> MachineReport<CounterContext> { host.report() }
}
