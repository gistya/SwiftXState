import Testing
@testable import SwiftXState

/// P2c: `StateMachine.isParallel` makes the machine *root* parallel — every top-level region runs at
/// once (XState's `createMachine({ type: 'parallel' })`). The BoardInspector's 64 independent squares
/// need this at the root (the `.root`-wrapper workaround would add a path segment its layout depends on).
@Suite("Plan D — parallel root (isParallel)")
struct DSLParallelRootTests {
    enum S: String, StateIdentifying {
        case a, aOn, aOff, b, bOn, bOff
        static var _blank: S { .a }
    }
    enum E: String, EventIdentifying { case aToggle, bToggle; static var _blank: E { .aToggle } }

    struct M: StateMachine {
        typealias Context = Int
        typealias StateID = S
        typealias EventID = E
        var context: Int { 0 }
        var isParallel: Bool { true }
        var machine: some XStateMachine {
            XState(.a) {
                XState(.aOff) { XTransition(on: .aToggle, to: .aOn) }.initial()
                XState(.aOn) { XTransition(on: .aToggle, to: .aOff) }
            }
            XState(.b) {
                XState(.bOff) { XTransition(on: .bToggle, to: .bOn) }.initial()
                XState(.bOn) { XTransition(on: .bToggle, to: .bOff) }
            }
        }
    }

    @Test func bothRegionsRunConcurrentlyAndIndependently() async {
        let m = createActor(M())
        await m.start()
        // Both top-level regions active simultaneously — the parallel-root proof.
        #expect(await m.matches(path: "a.aOff"))
        #expect(await m.matches(path: "b.bOff"))

        await m.send(.aToggle)
        #expect(await m.matches(path: "a.aOn"))
        #expect(await m.matches(path: "b.bOff"))   // region B untouched

        await m.send(.bToggle)
        #expect(await m.matches(path: "a.aOn"))     // region A retained
        #expect(await m.matches(path: "b.bOn"))
    }
}
