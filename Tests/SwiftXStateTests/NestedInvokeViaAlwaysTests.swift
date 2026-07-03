import Testing
@testable import SwiftXState

/// Regression coverage for a microstep exit-set bug that surfaced as SwiftRepoGUI's ProjectMachine
/// getting stuck "Discovering repositories…" forever.
///
/// Shape: an `Invoke` lives in a doubly-nested state (`loading.refreshing`) and its `onDone` targets a
/// state *outside* the invoke's parent (`.loaded`, a sibling of `loading`). The transition must exit
/// BOTH `refreshing` and the intermediate ancestor `loading`. `transitionRegionRoot` previously
/// returned the transition *source* as the exit-set boundary whenever there was no parallel ancestor,
/// which clamped the exit set to the source's own subtree — so `loading` was never exited. The machine
/// was left in a corrupt multi-branch configuration (`loading` active alongside `loaded`), and because
/// `loading.reloading`'s `Always(to: .refreshing)` kept re-firing off that stale branch, the invoke
/// re-ran on a loop — the visible "spins forever" symptom.
@Suite("Nested invoke onDone — exit-set escapes intermediate ancestors")
struct NestedInvokeViaAlwaysTests {
    struct Ctx: Sendable, Equatable {
        var path: String = "some/path"
        var info: String?
    }

    enum S: String, StateIdentifying {
        case ready, loading, reloading, refreshing, loaded
        static var _blank: S { .ready }
    }

    enum E: String, EventIdentifying {
        case pick
        static var _blank: E { .pick }
    }

    @Sendable static func work(_ scope: TaskActorScope) async -> String {
        try? await Task.sleep(for: .milliseconds(20))
        return "discovered-55-repos"
    }

    /// The exact app shape: `ready --pick--> loading.reloading --Always--> loading.refreshing`
    /// (invoke), `onDone --> .loaded` (outside `loading`).
    struct ViaAlways: StateMachine {
        typealias Context = Ctx; typealias StateID = S; typealias EventID = E
        var context: Ctx { Ctx() }
        var machine: some XStateMachine {
            XState(.ready) { XTransition(on: .pick, to: .reloading) }.initial()
            XState(.loading) {
                XState(.reloading) { Always(to: .refreshing).when { !$0.path.isEmpty } }.initial()
                XState(.refreshing) {
                    Invoke(id: "inspect", run: work)
                        .onDone(to: .loaded) { (o: String, c: Ctx) -> Ctx in var n = c; n.info = o; return n }
                }
            }
            XState(.loaded) {}
        }
    }

    /// Same nesting, but `onDone` targets an inner sibling (`.reloading`, still inside `loading`) — the
    /// LCA is `loading`, so `loading` must stay active and only `refreshing` exits.
    struct InnerTarget: StateMachine {
        typealias Context = Ctx; typealias StateID = S; typealias EventID = E
        var context: Ctx { Ctx() }
        var machine: some XStateMachine {
            XState(.ready) { XTransition(on: .pick, to: .refreshing) }.initial()
            XState(.loading) {
                XState(.refreshing) {
                    Invoke(id: "inspect", run: work)
                        .onDone(to: .reloading) { (o: String, c: Ctx) -> Ctx in var n = c; n.info = o; return n }
                }.initial()
                XState(.reloading) {}
            }
            XState(.loaded) {}
        }
    }

    @Test func onDoneToOuterStateExitsIntermediateAncestor() async {
        let m = createActor(ViaAlways())
        await m.start()
        await m.send(.pick)
        // Pre-fix this awaited until timeout because `.loaded` was never cleanly reached.
        await m.actor.waitForSnapshot { $0.value.matches("loaded") }
        #expect(await m.matches(.loaded))
        #expect(await m.context.info == "discovered-55-repos")
        // The invalid-config guard: the stale `loading` branch must be gone, not lingering alongside
        // `.loaded`. Before the fix `loading` stayed active and drove the re-inspection loop.
        #expect(!(await m.matches(.loading)))
    }

    @Test func onDoneToInnerSiblingStaysInsideParent() async {
        let m = createActor(InnerTarget())
        await m.start()
        await m.send(.pick)
        // Value settles to `loading.reloading`. `matches` is intentionally non-descending, so we assert
        // via the raw state value here (nested key) and the top-level compound via `matches`.
        await m.actor.waitForSnapshot { $0.value.matches("loading.reloading") }
        #expect(await m.matches(.loading))
        #expect(await m.context.info == "discovered-55-repos")
        #expect(!(await m.matches(.refreshing)))
        #expect(!(await m.matches(.loaded)))
    }
}
