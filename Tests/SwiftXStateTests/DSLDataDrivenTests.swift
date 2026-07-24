import Testing
@testable import SwiftXState

/// Mirrors the migrated SwiftXChess `OpeningMoveTreeMachine`: a **data-driven** machine whose states
/// and transitions are generated from a dictionary via a result-builder `for`-loop — the
/// `StateID == String` instantiation of the DSL — plus the inspector summary's `SAN.*` wildcard.
@Suite("SwiftXChess Phase 1 — data-driven (String) opening machine")
struct DSLDataDrivenTests {
    struct TreeCtx: Sendable, Equatable { var nodeId: String; var ply: Int }

    struct Tree: StateMachine {
        typealias Context = TreeCtx
        typealias StateID = String
        typealias EventID = String

        let nodes: [String: [String: String]]
        let rootId: String

        var context: TreeCtx { .init(nodeId: rootId, ply: 0) }

        var machine: some XStateMachine {
            let nodes = self.nodes
            let rootId = self.rootId
            for (nodeId, transitions) in nodes {
                buildNode(nodeId, transitions: transitions, isRoot: nodeId == rootId)
            }
        }

        func buildNode(_ id: String, transitions: [String: String], isRoot: Bool) -> XState<TreeCtx, String, String> {
            let state = XState(id) {
                for (event, target) in transitions {
                    XTransition(on: event, to: target).action { (context: TreeCtx) in
                        var c = context; c.nodeId = target; c.ply += 1; return c
                    }
                }
            }
            return isRoot ? state.initial() : state
        }
    }

    @Test func navigatesTheGeneratedTree() async {
        let nodes: [String: [String: String]] = [
            "root": ["SAN.e4": "pos_e4", "SAN.d4": "pos_d4"],
            "pos_e4": ["SAN.e5": "pos_e4e5"],
            "pos_d4": [:],
            "pos_e4e5": [:],
        ]
        let t = createActor(Tree(nodes: nodes, rootId: "root"))
        await t.start()
        #expect(await t.matches("root"))
        #expect(await t.context.nodeId == "root")

        await t.send("SAN.e4")
        #expect(await t.matches("pos_e4"))
        #expect(await t.context.nodeId == "pos_e4")
        #expect(await t.context.ply == 1)

        await t.send("SAN.e5")
        #expect(await t.matches("pos_e4e5"))
        #expect(await t.context.ply == 2)

        // An unavailable move at this leaf is a no-op.
        await t.send("SAN.zz")
        #expect(await t.matches("pos_e4e5"))
    }

    struct Summary: StateMachine {
        typealias Context = Int
        typealias StateID = String
        typealias EventID = String
        var context: Int { 0 }
        var machine: some XStateMachine {
            XState("tracking") {
                XTransition(on: "SAN.*", to: "tracking")
            }
            .initial()
        }
    }

    @Test func wildcardSelfTransitionStaysTracking() async {
        let s = createActor(Summary())
        await s.start()
        #expect(await s.matches("tracking"))
        await s.send("SAN.Nf3")        // matched by the SAN.* wildcard
        #expect(await s.matches("tracking"))
    }
}
