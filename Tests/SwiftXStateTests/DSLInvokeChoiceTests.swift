import Testing
@testable import SwiftXState

@Suite("Plan D — choice / entry-exit enq / invoke")
struct DSLInvokeChoiceTests {
    // MARK: - choice state (computed target)

    enum Tier: String, StateIdentifying, CaseIterable {
        case decide, vip, standard
        static var _blank: Tier { .decide }
    }
    enum TierEvent: String, EventIdentifying { case go; static var _blank: TierEvent { .go } }

    struct Router: StateMachine {
        typealias Context = Bool   // isVip
        typealias StateID = Tier
        typealias EventID = TierEvent
        var context: Bool { false }
        var machine: some XStateMachine {
            // `decide` is the initial choice state: on entry it computes its target from context.
            XState(.decide).choice { isVip in isVip ? .vip : .standard }.initial()
            XState(.vip) {}
            XState(.standard) {}
        }
    }

    @Test func choiceRoutesByContext() async {
        let vip = createActor(Router())
        await vip.start(context: true)      // decide → (choice) vip
        #expect(await vip.matches(.vip))

        let normal = createActor(Router())
        await normal.start(context: false)  // decide → (choice) standard
        #expect(await normal.matches(.standard))
    }

    // MARK: - entry/exit in the enq form

    enum Gate: String, StateIdentifying { case closed, opening, open; static var _blank: Gate { .closed } }
    enum GateEvent: String, EventIdentifying { case open, opened; static var _blank: GateEvent { .open } }

    /// `opening`'s entry handler raises `.opened` (the enq effect form), auto-advancing to `open`;
    /// `open`'s entry patches context.
    struct AutoGate: StateMachine {
        typealias Context = Int
        typealias StateID = Gate
        typealias EventID = GateEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.closed) { XTransition(on: .open, to: .opening) }.initial()
            XState(.opening) {
                XTransition(on: .opened, to: .open)
            }
            .onEntry { _, enq in
                enq.raise(.opened)          // entry effect: raise, RTC-safe
                return 0
            }
            XState(.open) {}
                .onEntry { ctx in ctx + 1 } // entry pure patch
        }
    }

    @Test func entryEnqRaiseAutoAdvances() async {
        let g = createActor(AutoGate())
        await g.start()
        await g.send(.open)                 // closed → opening, entry raises opened → open
        #expect(await g.matches(.open))
        #expect(await g.context == 1)       // open's entry patch ran
    }

    // MARK: - invoke (async task)

    enum Load: String, StateIdentifying { case idle, loading, loaded, failed; static var _blank: Load { .idle } }
    enum LoadEvent: String, EventIdentifying { case fetch; static var _blank: LoadEvent { .fetch } }

    struct Loader: StateMachine {
        typealias Context = Bool   // shouldSucceed
        typealias StateID = Load
        typealias EventID = LoadEvent
        var context: Bool { true }
        var machine: some XStateMachine {
            XState(.idle) { XTransition(on: .fetch, to: .loading) }.initial()
            XState(.loading) {
                Invoke(id: "load", run: { (scope: TaskActorScope) -> String in
                    let ok = scope.input?.get(Bool.self) ?? true
                    guard ok else { throw LoaderError.boom }
                    return "data"
                })
                .input { ok in SendableValue(ok) }
                .onDone(to: .loaded)
                .onError(to: .failed)
            }
            XState(.loaded) {}
            XState(.failed) {}
        }
    }
    enum LoaderError: Error { case boom }

    @Test func invokeTaskOnDone() async {
        let m = createActor(Loader())
        await m.start(context: true)
        await m.send(.fetch)                            // → loading, invokes the task
        await m.actor.waitForSnapshot { $0.value.matches("loaded") }
        #expect(await m.matches(.loaded))
    }

    @Test func invokeTaskOnError() async {
        let m = createActor(Loader())
        await m.start(context: false)                   // input false → task throws
        await m.send(.fetch)
        await m.actor.waitForSnapshot { $0.value.matches("failed") }
        #expect(await m.matches(.failed))
    }

    // MARK: - invoke (child machine)

    enum ChildState: String, StateIdentifying { case running, done; static var _blank: ChildState { .running } }
    enum ChildEvent: String, EventIdentifying { case finish; static var _blank: ChildEvent { .finish } }

    struct Child: StateMachine {
        typealias Context = Int
        typealias StateID = ChildState
        typealias EventID = ChildEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            // Auto-completes: running → (always) done(final), so the invocation finishes on its own.
            XState(.running) { Always(to: .done) }.initial()
            XState(.done) {}.final()        // child reaching final completes the invocation
        }
    }

    enum Parent: String, StateIdentifying { case waiting, completed; static var _blank: Parent { .waiting } }
    enum ParentEvent: String, EventIdentifying { case poke; static var _blank: ParentEvent { .poke } }

    struct ParentMachine: StateMachine {
        typealias Context = Int
        typealias StateID = Parent
        typealias EventID = ParentEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.waiting) {
                Invoke(id: "child", machine: Child()).onDone(to: .completed)
            }.initial()
            XState(.completed) {}
        }
    }

    @Test func invokeChildMachineOnDone() async {
        let p = createActor(ParentMachine())
        await p.start()
        // The invoked child auto-completes (running → done/final), so the parent's onDone fires.
        await p.actor.waitForSnapshot { $0.value.matches("completed") }
        #expect(await p.matches(.completed))
    }
}
