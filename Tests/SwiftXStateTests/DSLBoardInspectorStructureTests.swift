import Testing
@testable import SwiftXState

/// Mirrors the migrated SwiftXChess `BoardInspectorMachine` *structure* (which lives in the
/// unbuildable-here .xcodeproj): a **parallel-root**, **data-driven** `String`/`String` machine whose
/// square regions are built with a result-builder `for`-loop, each compound region seeded to the right
/// initial child, occupancy driven by per-coord **wildcard** events. Exercises P2b (shared inner-state
/// names `empty`/`occupied` resolve to the right sibling per region) + P2c (parallel root).
@Suite("SwiftXChess Phase 2 — BoardInspector structure (parallel data-driven board)")
struct DSLBoardInspectorStructureTests {
    struct MiniBoard: StateMachine {
        typealias Context = Int
        typealias StateID = String
        typealias EventID = String

        static let coords = ["a1", "a2", "b1", "b2"]
        let occupied: Set<String>

        var isParallel: Bool { true }
        var context: Int { 0 }

        var machine: some XStateMachine {
            let occupied = self.occupied
            for coord in Self.coords {
                region(coord: coord, occupied: occupied.contains(coord))
            }
        }

        private func region(coord: String, occupied: Bool) -> XState<Int, String, String> {
            XState(coord) {
                initialIf(!occupied, XState("empty") {
                    XTransition(on: "SQUARE.OCCUPY.\(coord).*", to: "occupied")
                })
                initialIf(occupied, XState("occupied") {
                    XTransition(on: "SQUARE.CLEAR.\(coord)", to: "empty")
                })
            }
        }

        private func initialIf(_ flag: Bool, _ state: XState<Int, String, String>) -> XState<Int, String, String> {
            flag ? state.initial() : state
        }
    }

    /// The `.pieces` hub-and-spoke variant: `empty` + N piece types per region, both built with
    /// result-builder `for`-loops (a for-loop of transitions inside `empty`, a for-loop of states).
    struct MiniPiecesBoard: StateMachine {
        typealias Context = Int
        typealias StateID = String
        typealias EventID = String

        static let coords = ["a1", "b1"]
        static let types = ["wP", "wN", "bP"]
        let occupant: [String: String]   // coord -> type

        var isParallel: Bool { true }
        var context: Int { 0 }

        var machine: some XStateMachine {
            let occupant = self.occupant
            for coord in Self.coords {
                region(coord: coord, initialType: occupant[coord])
            }
        }

        private func region(coord: String, initialType: String?) -> XState<Int, String, String> {
            XState(coord) {
                initialIf(initialType == nil, XState("empty") {
                    for type in Self.types {
                        XTransition(on: "SQUARE.OCCUPY.\(coord).\(type).*", to: type)
                    }
                })
                for type in Self.types {
                    initialIf(initialType == type, XState(type) {
                        XTransition(on: "SQUARE.CLEAR.\(coord)", to: "empty")
                    })
                }
            }
        }

        private func initialIf(_ flag: Bool, _ state: XState<Int, String, String>) -> XState<Int, String, String> {
            flag ? state.initial() : state
        }
    }

    @Test func piecesModeHubAndSpokeRoutesByType() async {
        let m = createActor(MiniPiecesBoard(occupant: ["a1": "wP"]))
        await m.start()
        #expect(await m.matches(path: "a1.wP"))      // seeded to its piece type
        #expect(await m.matches(path: "b1.empty"))

        await m.send("SQUARE.OCCUPY.b1.wN.1")        // route to the matching type
        #expect(await m.matches(path: "b1.wN"))
        await m.send("SQUARE.CLEAR.b1")              // back through empty
        #expect(await m.matches(path: "b1.empty"))
        #expect(await m.matches(path: "a1.wP"))      // a1 untouched
    }

    @Test func everySquareSeededAndRoutesIndependently() async {
        let m = createActor(MiniBoard(occupied: ["a1"]))
        await m.start()
        // Parallel root: all four regions active at once, each seeded from the layout.
        #expect(await m.matches(path: "a1.occupied"))
        #expect(await m.matches(path: "a2.empty"))
        #expect(await m.matches(path: "b1.empty"))
        #expect(await m.matches(path: "b2.empty"))

        // Wildcard occupy routes to b1 only (the coord is in the event pattern).
        await m.send("SQUARE.OCCUPY.b1.wP.1")
        #expect(await m.matches(path: "b1.occupied"))
        #expect(await m.matches(path: "a1.occupied"))   // untouched
        #expect(await m.matches(path: "a2.empty"))      // untouched

        // Clear routes to a1 only — shared name `empty` resolves to a1's own sibling (P2b relative).
        await m.send("SQUARE.CLEAR.a1")
        #expect(await m.matches(path: "a1.empty"))
        #expect(await m.matches(path: "b1.occupied"))   // b1 retained
    }
}
