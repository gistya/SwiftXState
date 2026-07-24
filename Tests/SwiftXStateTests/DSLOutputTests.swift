import Testing
@testable import SwiftXState

@Suite("Plan D — output in onDone / onError (v6 alpha.8)")
struct DSLOutputTests {
    // MARK: - invoke task output

    enum Load: String, StateIdentifying { case idle, loading, loaded, failed; static var _blank: Load { .idle } }
    enum LoadEvent: String, EventIdentifying { case fetch; static var _blank: LoadEvent { .fetch } }

    struct Loader: StateMachine {
        typealias Context = String   // collects the loaded value / error
        typealias StateID = Load
        typealias EventID = LoadEvent
        var context: String { "" }
        var machine: some XStateMachine {
            XState(.idle) { XTransition(on: .fetch, to: .loading) }.initial()
            XState(.loading) {
                Invoke(id: "load", run: { (scope: TaskActorScope) -> String in
                    let ok = scope.input?.get(Bool.self) ?? true
                    guard ok else { throw LoaderError.boom("kaboom") }
                    return "payload-42"
                })
                .input { _ in SendableValue(true) }
                .onDone(to: .loaded) { (output: String, _) in output }      // child output → context
                .onError(to: .failed) { error, _ in "error:\(error)" }       // error string → context
            }
            XState(.loaded) {}
            XState(.failed) {}
        }
    }
    enum LoaderError: Error, CustomStringConvertible {
        case boom(String)
        var description: String { if case let .boom(m) = self { return m } else { return "" } }
    }

    @Test func invokeOnDoneReadsTaskOutput() async {
        let m = createActor(Loader())
        await m.start()
        await m.send(.fetch)
        await m.actor.waitForSnapshot { $0.value.matches("loaded") }
        #expect(await m.matches(.loaded))
        #expect(await m.context == "payload-42")   // the task's return value flowed into context
    }

    // MARK: - invoke onError reads the error

    struct FailLoader: StateMachine {
        typealias Context = String
        typealias StateID = Load
        typealias EventID = LoadEvent
        var context: String { "" }
        var machine: some XStateMachine {
            XState(.idle) { XTransition(on: .fetch, to: .loading) }.initial()
            XState(.loading) {
                Invoke(id: "load", run: { (_: TaskActorScope) -> String in throw LoaderError.boom("nope") })
                    .onDone(to: .loaded)
                    .onError(to: .failed) { error, _ in "error:\(error)" }
            }
            XState(.loaded) {}
            XState(.failed) {}
        }
    }

    @Test func invokeOnErrorReadsError() async {
        let m = createActor(FailLoader())
        await m.start()
        await m.send(.fetch)
        await m.actor.waitForSnapshot { $0.value.matches("failed") }
        #expect(await m.matches(.failed))
        #expect(await m.context.hasPrefix("error:"))   // the error string reached the context
    }

    // MARK: - child-machine output + final-state output + OnDone reading it

    enum Worker: String, StateIdentifying { case working, done; static var _blank: Worker { .working } }
    enum WorkerEvent: String, EventIdentifying { case go; static var _blank: WorkerEvent { .go } }

    /// The child reaches a `.final()` state that produces typed `output` from its context.
    struct WorkerMachine: StateMachine {
        typealias Context = Int
        typealias StateID = Worker
        typealias EventID = WorkerEvent
        var context: Int { 7 }
        var machine: some XStateMachine {
            XState(.working) { Always(to: .done) }.initial()
            XState(.done) {}.final().output { ctx in ctx * 100 }   // final output = 700
        }
    }

    enum Boss: String, StateIdentifying { case waiting, summarized; static var _blank: Boss { .waiting } }
    enum BossEvent: String, EventIdentifying { case poke; static var _blank: BossEvent { .poke } }

    struct BossMachine: StateMachine {
        typealias Context = Int
        typealias StateID = Boss
        typealias EventID = BossEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.waiting) {
                Invoke(id: "worker", machine: WorkerMachine())
                    .onDone(to: .summarized) { (output: Int, _) in output }   // child's final output
            }.initial()
            XState(.summarized) {}
        }
    }

    @Test func childMachineFinalOutputFlowsToParentOnDone() async {
        let p = createActor(BossMachine())
        await p.start()
        await p.actor.waitForSnapshot { $0.value.matches("summarized") }
        #expect(await p.matches(.summarized))
        #expect(await p.context == 700)   // worker's final-state output (7 * 100) read in parent onDone
    }

    // MARK: - OnDone reading a compound region's final output

    enum Flow: String, StateIdentifying { case running, step, finished, summary; static var _blank: Flow { .running } }
    enum FlowEvent: String, EventIdentifying { case next; static var _blank: FlowEvent { .next } }

    struct FlowMachine: StateMachine {
        typealias Context = Int
        typealias StateID = Flow
        typealias EventID = FlowEvent
        var context: Int { 5 }
        var machine: some XStateMachine {
            XState(.running) {
                OnDone(to: .summary).action(reading: Int.self) { output, _ in output }   // region output
                XState(.step) { Always(to: .finished) }.initial()
                XState(.finished) {}.final().output { ctx in ctx + 1 }   // 5 + 1 = 6
            }.initial()
            XState(.summary) {}
        }
    }

    @Test func onDoneReadsRegionFinalOutput() async {
        let m = createActor(FlowMachine())
        await m.start()
        await m.actor.waitForSnapshot { $0.value.matches("summary") }
        #expect(await m.matches(.summary))
        #expect(await m.context == 6)   // finished's output (5 + 1) read by the parent OnDone
    }
}
