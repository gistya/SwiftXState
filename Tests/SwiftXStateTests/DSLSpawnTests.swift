import Testing
@testable import SwiftXState

@Suite("Plan D — enq.spawn (dynamic child actors)")
struct DSLSpawnTests {
    enum TileState: String, StateIdentifying { case on, off; static var _blank: TileState { .off } }
    enum TileEvent: String, EventIdentifying { case flip; static var _blank: TileEvent { .flip } }
    struct Tile: StateMachine {
        typealias Context = Int
        typealias StateID = TileState
        typealias EventID = TileEvent
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState(.off) { XTransition(on: .flip, to: .on) }.initial()
            XState(.on) { XTransition(on: .flip, to: .off) }
        }
    }

    static let coords = ["a1", "b2", "c3", "d4"]

    @Test func spawnFleetFromTransition() async {
        enum S: String, StateIdentifying { case idle, running; static var _blank: S { .idle } }
        enum E: String, EventIdentifying { case populate; static var _blank: E { .populate } }
        struct Board: StateMachine {
            typealias Context = Int; typealias StateID = S; typealias EventID = E
            var context: Int { 0 }
            var machine: some XStateMachine {
                XState(.idle) {
                    XTransition(on: .populate, to: .running).action { _, enq in
                        for c in DSLSpawnTests.coords { enq.spawn(Tile(), id: "tile.\(c)", inspectable: false) }
                        return 0
                    }
                }.initial()
                XState(.running) {}
            }
        }
        let board = createActor(Board())
        await board.start()
        await board.send(.populate)
        await board.actor.waitForSnapshot { $0.children.count == 4 }
        let kids = await board.actor.snapshot.children
        #expect(Set(kids.keys) == ["tile.a1", "tile.b2", "tile.c3", "tile.d4"])
        #expect(kids.values.allSatisfy { $0.status == .active })
    }

    @Test func spawnFleetFromEnteredStateEntry() async {
        // Entry of a NON-initial state, entered via a transition.
        enum S: String, StateIdentifying { case idle, running; static var _blank: S { .idle } }
        enum E: String, EventIdentifying { case go; static var _blank: E { .go } }
        struct Board: StateMachine {
            typealias Context = Int; typealias StateID = S; typealias EventID = E
            var context: Int { 0 }
            var machine: some XStateMachine {
                XState(.idle) { XTransition(on: .go, to: .running) }.initial()
                XState(.running) {}
                    .onEntry { _, enq in
                        for c in DSLSpawnTests.coords { enq.spawn(Tile(), id: "tile.\(c)", inspectable: false) }
                        return 0
                    }
            }
        }
        let board = createActor(Board())
        await board.start()
        await board.send(.go)
        await board.actor.waitForSnapshot { $0.children.count == 4 }
        #expect(await board.actor.snapshot.children.count == 4)
    }

    @Test func stopChildRemovesIt() async {
        enum S: String, StateIdentifying { case running; static var _blank: S { .running } }
        enum E: String, EventIdentifying { case spawnOne, stopOne; static var _blank: E { .spawnOne } }
        struct Solo: StateMachine {
            typealias Context = Int; typealias StateID = S; typealias EventID = E
            var context: Int { 0 }
            var machine: some XStateMachine {
                XState(.running) {
                    XTransition(on: .spawnOne, to: .running).action { _, enq in enq.spawn(Tile(), id: "solo", inspectable: false); return 0 }
                    XTransition(on: .stopOne, to: .running).action { _, enq in enq.stopChild("solo"); return 0 }
                }.initial()
            }
        }
        let s = createActor(Solo())
        await s.start()
        await s.send(.spawnOne)
        await s.actor.waitForSnapshot { $0.children["solo"] != nil }
        await s.send(.stopOne)
        await s.actor.waitForSnapshot { $0.children["solo"] == nil }
        #expect(await s.actor.snapshot.children["solo"] == nil)
    }
}
