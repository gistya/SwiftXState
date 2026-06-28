import Testing
@testable import SwiftXState

@Suite("Plan D — structural nodes (always / after / onDone / final)")
struct DSLStructuralTests {
    // MARK: - always (eventless / choice)

    enum Gate: String, StateIdentifying {
        case start, check, approved, declined
        static var _blank: Gate { .start }
    }
    enum GateEvent: String, EventIdentifying { case go; static var _blank: GateEvent { .go } }

    /// `check` is a choice point: the first `Always` whose guard passes wins.
    struct Scoring: StateMachine {
        typealias Context = Int      // score
        typealias StateID = Gate
        typealias EventID = GateEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.start) { XTransition(on: .go, to: .check) }.initial()
            XState(.check) {
                Always(to: .approved).when { $0 >= 700 }
                Always(to: .declined)
            }
            XState(.approved) {}
            XState(.declined) {}
        }
    }

    @Test func alwaysSchemaCarriesGuardedTransitions() {
        let check = Scoring().buildSchema().states[.check]
        #expect(check?.always.count == 2)
        #expect(check?.always.first?.target == .approved)
        #expect(check?.always.first?.guard != nil)
        #expect(check?.always.last?.guard == nil)   // the fallback
    }

    @Test func alwaysResolvesByGuard() async {
        let high = createActor(Scoring())
        await high.start(context: 750)
        await high.send(.go)          // start → check → (always) approved
        #expect(await high.matches(.approved))

        let low = createActor(Scoring())
        await low.start(context: 300)
        await low.send(.go)           // start → check → (always) declined
        #expect(await low.matches(.declined))
    }

    // MARK: - after (delayed)

    enum Load: String, StateIdentifying {
        case idle, loading, loaded, timedOut
        static var _blank: Load { .idle }
    }
    enum LoadEvent: String, EventIdentifying { case fetch, resolve; static var _blank: LoadEvent { .fetch } }

    struct Loader: StateMachine {
        typealias Context = Int
        typealias StateID = Load
        typealias EventID = LoadEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.idle) { XTransition(on: .fetch, to: .loading) }.initial()
            XState(.loading) {
                XTransition(on: .resolve, to: .loaded)
                After(.seconds(5), to: .timedOut)
            }
            XState(.loaded) {}
            XState(.timedOut) {}
        }
    }

    @Test func afterSchemaCarriesDelay() {
        let loading = Loader().buildSchema().states[.loading]
        #expect(loading?.after.count == 1)
        #expect(loading?.after.first?.delayMS == 5000)
        #expect(loading?.after.first?.transition.target == .timedOut)
    }

    @Test func afterFiresOnDelayElapsed() async {
        let clock = SimulatedClock()
        let m = createActor(Loader(), options: ActorOptions(clock: clock))
        await m.start()
        await m.send(.fetch)                       // → loading (arms the 5s timer)
        #expect(await m.matches(.loading))

        clock.increment(4_000)
        #expect(await m.matches(.loading))         // not yet

        clock.increment(1_500)                      // past 5s
        await m.actor.waitForSnapshot { $0.value.matches("timedOut") }
        #expect(await m.matches(.timedOut))
    }

    @Test func afterIsCancelledByEarlierEvent() async {
        let clock = SimulatedClock()
        let m = createActor(Loader(), options: ActorOptions(clock: clock))
        await m.start()
        await m.send(.fetch)                        // → loading
        await m.send(.resolve)                      // → loaded, before the timer
        #expect(await m.matches(.loaded))

        clock.increment(10_000)                     // timer should have been cancelled on exit
        #expect(await m.matches(.loaded))           // still loaded, not timedOut
    }

    // MARK: - onDone + final

    enum Wizard: String, StateIdentifying {
        case wizard, step1, step2, finished, summary
        static var _blank: Wizard { .wizard }
    }
    enum WizardEvent: String, EventIdentifying { case next; static var _blank: WizardEvent { .next } }

    /// `wizard` is a compound whose `finished` child is `.final()`; reaching it completes the wizard
    /// and fires its `OnDone` → `summary`.
    struct Flow: StateMachine {
        typealias Context = Int
        typealias StateID = Wizard
        typealias EventID = WizardEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.wizard) {
                OnDone(to: .summary)
                XState(.step1) { XTransition(on: .next, to: .step2) }.initial()
                XState(.step2) { XTransition(on: .next, to: .finished) }
                XState(.finished) {}.final()
            }
            .initial()
            XState(.summary) {}
        }
    }

    @Test func onDoneAndFinalSchema() {
        let wizard = Flow().buildSchema().states[.wizard]
        #expect(wizard?.onDone.count == 1)
        #expect(wizard?.onDone.first?.target == .summary)
        #expect(wizard?.children.first(where: { $0.id == .finished })?.nodeType == .final)
    }

    @Test func reachingFinalFiresOnDone() async {
        let m = createActor(Flow())
        await m.start()
        #expect(await m.matches(path: "wizard.step1"))
        await m.send(.next)                          // step1 → step2
        #expect(await m.matches(path: "wizard.step2"))
        let done = await m.send(.next)               // step2 → finished(final) → wizard done → summary
        #expect(done == .atomic(.summary))
    }
}
