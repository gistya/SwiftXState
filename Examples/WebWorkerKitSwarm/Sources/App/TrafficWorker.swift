import Distributed
import WebWorkerKit
import SwiftXStateDistributed

// A *second* distinct `distributed actor` type — which means a *second* Web Worker (a
// second OS thread). WebWorkerKit keys workers by mangled type name and allows one instance
// per type, so two types give two independent workers. This one hosts the traffic-light
// machine; `CounterWorker` hosts the counter. Same shape, different machine.
distributed actor TrafficWorker: WebWorker {
    typealias ActorSystem = WebWorkerActorSystem

    static let scriptPath: String? = "./worker.js"
    static let isModule = false

    private let host = MachineHost(makeTrafficLight())

    nonisolated static func == (lhs: TrafficWorker, rhs: TrafficWorker) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    distributed func send(_ event: String) -> MachineReport<TrafficContext> { host.send(event) }
    distributed func report() -> MachineReport<TrafficContext> { host.report() }

    /// Burn CPU *inside this worker's thread* — used by the parallelism demo.
    distributed func busy(_ rounds: Int) -> Int { spin(rounds) }
}
