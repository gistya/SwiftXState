import Testing
@testable import SwiftXState

@Suite("Plan D — event-aware guards (XState's {context, event} => bool)")
struct DSLEventGuardTests {
    enum VaultState: String, StateIdentifying { case locked, open; static var _blank: VaultState { .locked } }
    enum VaultEvent: EventIdentifying { case knock(code: String); static var _blank: VaultEvent { .knock(code: "") } }

    /// Opens only when the knocked code matches the secret in context — the guard needs BOTH the
    /// event payload and the context (the case the context-only `.when` can't express).
    struct Vault: StateMachine {
        typealias Context = String   // the secret
        typealias StateID = VaultState
        typealias EventID = VaultEvent
        var context: String { "1234" }
        var machine: some XStateMachine {
            XState(.locked) {
                XTransition(on: VaultEvent.knock, to: .open).when { secret, event in
                    guard case let .knock(code)? = event else { return false }
                    return code == secret
                }
            }.initial()
            XState(.open) {}
        }
    }

    @Test func eventAwareGuardReadsContextAndEvent() async {
        let wrong = createActor(Vault())
        await wrong.start()
        await wrong.send(.knock(code: "0000"))
        #expect(await wrong.matches(.locked))     // wrong code → guard fails → stays locked

        let right = createActor(Vault())
        await right.start()
        await right.send(.knock(code: "1234"))
        #expect(await right.matches(.open))       // matching code → guard passes → opens
    }

    @Test func contextOnlyAndEventAwareGuardsCompose() async {
        // A context-only `.when` AND an event-aware `.when` on the same transition both must pass.
        struct Gate: StateMachine {
            typealias Context = Bool   // enabled
            typealias StateID = VaultState
            typealias EventID = VaultEvent
            var context: Bool { true }
            var machine: some XStateMachine {
                XState(.locked) {
                    XTransition(on: VaultEvent.knock, to: .open)
                        .when { enabled in enabled }                       // context-only
                        .when { _, event in                                // event-aware
                            if case let .knock(code)? = event { return code == "open" }
                            return false
                        }
                }.initial()
                XState(.open) {}
            }
        }
        let g = createActor(Gate())
        await g.start(context: true)
        await g.send(.knock(code: "nope"))
        #expect(await g.matches(.locked))         // event guard fails
        await g.send(.knock(code: "open"))
        #expect(await g.matches(.open))           // both pass

        let disabled = createActor(Gate())
        await disabled.start(context: false)
        await disabled.send(.knock(code: "open"))
        #expect(await disabled.matches(.locked))  // context guard fails even with right code
    }
}
