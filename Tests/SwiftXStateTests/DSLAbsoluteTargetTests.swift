import Testing
@testable import SwiftXState

/// P2b: a transition target whose id `name` is unique in the tree lowers to an absolute `#full.path`,
/// so a deep **cross-branch** jump resolves — the GameWatcher pattern `replaying → game.active.turn.idle`,
/// which bare-name (sibling/child-only) resolution could not reach. Shared names stay relative
/// (covered by the castling structure test).
@Suite("Plan D — absolute / cross-branch transition targets")
struct DSLAbsoluteTargetTests {
    enum S: String, StateIdentifying {
        case game, active, turn, idle, replaying
        static var _blank: S { .game }
    }
    enum E: String, EventIdentifying { case replay, exit; static var _blank: E { .replay } }

    struct M: StateMachine {
        typealias Context = Int
        typealias StateID = S
        typealias EventID = E
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.game) {
                XState(.active) {
                    XState(.turn) {
                        XState(.idle) {
                            XTransition(on: .replay, to: .replaying)   // deep → sibling-of-active
                        }.initial()
                    }.initial()
                }.initial()
                XState(.replaying) {
                    XTransition(on: .exit, to: .idle)                 // → deep cross-branch (the hard one)
                }
            }.initial()
        }
    }

    @Test func deepCrossBranchTargetResolvesBothWays() async {
        let m = createActor(M())
        await m.start()
        #expect(await m.matches(path: "game.active.turn.idle"))

        await m.send(.replay)
        #expect(await m.matches(path: "game.replaying"))

        // The cross-branch deep target: replaying → game.active.turn.idle.
        await m.send(.exit)
        #expect(await m.matches(path: "game.active.turn.idle"))

        // Round-trip proves we genuinely re-entered the nested idle (not a half-resolved state).
        await m.send(.replay)
        #expect(await m.matches(path: "game.replaying"))
    }
}
