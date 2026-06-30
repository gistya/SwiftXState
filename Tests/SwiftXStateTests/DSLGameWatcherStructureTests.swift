import Testing
@testable import SwiftXState

/// Mirrors the migrated SwiftXChess `GameWatcherMachine` *construct set* (the orchestrator lives in the
/// unbuildable-here .xcodeproj): `boot` spawns a child from its entry then resolves to `game`; the
/// `game.active.turn` play loop (idle/selecting/promoting) is driven by always-guards over context; a
/// self-targeting `tap` handler fans a payload-bearing command to a spawned child (P2a); `replaying`
/// jumps to/from the deep `game.active.turn.idle` (P2b absolute targets); `newGame` stops children and
/// resets back through `boot`.
@Suite("SwiftXChess Phase 2 — GameWatcher construct set (orchestrator)")
struct DSLGameWatcherStructureTests {
    actor Recorder {
        private(set) var received: [Int] = []
        func add(_ v: Int) { received.append(v) }
        var count: Int { received.count }
    }

    // A board-child-like machine that records the payload of a command from the orchestrator.
    enum CS: String, StateIdentifying { case empty, full; static var _blank: CS { .empty } }
    enum CE: EventIdentifying { case occupy(id: Int), clear; static var _blank: CE { .clear } }
    struct Child: StateMachine {
        typealias Context = Int
        typealias StateID = CS
        typealias EventID = CE
        let recorder: Recorder
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.empty) {
                XTransition(on: CE.occupy, to: .full).action { args, _ in
                    if case let .occupy(id)? = args.event {
                        let r = recorder
                        Task { await r.add(id) }
                    }
                    return args.context
                }
            }.initial()
            XState(.full) { XTransition(on: .clear, to: .empty) }
        }
    }

    struct Ctx: Sendable, Equatable { var selected: Int?; var promo = false; var outcome = false }
    enum S: String, StateIdentifying {
        case boot, game, active, turn, idle, selecting, promoting, finished, replaying
        static var _blank: S { .boot }
    }
    enum E: EventIdentifying { case tap(Int), newGame, enterReplay, exitReplay; static var _blank: E { .newGame } }

    struct Watcher: StateMachine {
        typealias Context = Ctx
        typealias StateID = S
        typealias EventID = E
        let recorder: Recorder
        var context: Ctx { .init(selected: nil) }

        var machine: some XStateMachine {
            bootState()
            gameState()
        }

        private func bootState() -> XState<Ctx, E, S> {
            let rec = recorder
            return XState(.boot) { Always(to: .game) }
                .initial()
                .onEntry { args, enq in
                    enq.spawn(Child(recorder: rec), id: "c0", inspectable: false)
                    return args.context
                }
        }

        private func gameState() -> XState<Ctx, E, S> {
            XState(.game) {
                XState(.active) {
                    XState(.turn) {
                        XState(.idle) {
                            Always(to: .selecting).when { $0.selected != nil && !$0.promo }
                            Always(to: .promoting).when { $0.promo }
                        }.initial()
                        XState(.selecting) {
                            Always(to: .idle).when { $0.selected == nil }
                        }
                        XState(.promoting) {
                            Always(to: .idle).when { !$0.promo }
                        }
                        tapHandler()
                        XTransition(on: .newGame, to: .boot).action { _, enq in
                            enq.stopChild("c0")
                            return Ctx(selected: nil)
                        }
                        XTransition(on: .enterReplay, to: .replaying).action { args, _ in args.context }
                    }.initial()
                    Always(to: .finished).when { $0.outcome }
                }.initial()
                XState(.finished) {
                    XTransition(on: .enterReplay, to: .replaying).action { args, _ in args.context }
                }
                XState(.replaying) {
                    // Mirrors GameWatcherReplay.exit restoring a non-finished snapshot.
                    XTransition(on: .exitReplay, to: .idle).action { args, _ in
                        var c = args.context; c.outcome = false; c.selected = nil; return c
                    }
                }
            }
        }

        // Self-targeting `turn` — a tap either selects (sets `selected`) or, on the sentinel move 9,
        // commits: clears selection, sets outcome, and dispatches a payload command to the child.
        private func tapHandler() -> XTransition<Ctx, E, S> {
            XTransition(on: E.tap, to: .turn).action { args, enq in
                var c = args.context
                guard case let .tap(v)? = args.event else { return c }
                if v == 9 {
                    c.selected = nil
                    c.outcome = true
                    enq.sendTo("c0", CE.occupy(id: 9))
                } else {
                    c.selected = v
                }
                return c
            }
        }
    }

    @Test func orchestratorPlayLoopReplayAndDispatch() async {
        let recorder = Recorder()
        let w = createActor(Watcher(recorder: recorder))
        await w.start()
        await w.actor.waitForSnapshot { $0.children["c0"] != nil }  // boot entry spawned the child
        #expect(await w.matches(path: "game.active.turn.idle"))

        await w.send(.tap(3))   // select → selecting (always-guard)
        #expect(await w.matches(path: "game.active.turn.selecting"))

        await w.send(.tap(9))   // commit move: outcome → finished, payload dispatched to child
        #expect(await w.matches(path: "game.finished"))
        var spins = 0
        while await recorder.count < 1, spins < 10_000 { await Task.yield(); spins += 1 }
        #expect(await recorder.received == [9])   // P2a: the Int payload crossed to the child

        await w.send(.enterReplay)
        #expect(await w.matches(path: "game.replaying"))

        await w.send(.exitReplay)   // P2b: deep cross-branch back to game.active.turn.idle
        #expect(await w.matches(path: "game.active.turn.idle"))
    }
}
