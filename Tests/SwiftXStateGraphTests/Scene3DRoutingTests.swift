#if SWIFTXSTATE_GRAPH_UI && canImport(SceneKit) && !os(watchOS)
import Testing
import simd
@testable import SwiftXStateGraph

/// Invariants for the pure-Swift 3D cross-edge router (`GraphScene3DView.routeEdges3D`): bundled edges
/// fan to distinct, non-coincident curves (including reverse-direction ones), and a curve arcs clear of
/// nodes it doesn't touch.
@Suite("3D edge routing")
struct Scene3DRoutingTests {
    private func edge(_ id: String, _ from: String, _ to: String) -> GraphEdge {
        GraphEdge(id: id, from: from, to: to, label: id, kind: .event, isGuarded: false)
    }

    @Test("Anti-parallel edges route to distinct, non-coincident curves")
    func antiParallelSeparate() {
        let pos: [String: SIMD3<Float>] = ["a": [-4, 0, 0], "b": [4, 0, 0]]
        let foot: [String: Float] = ["a": 1.3, "b": 1.3]
        let routes = GraphScene3DView.routeEdges3D(
            edges: [edge("f", "a", "b"), edge("r", "b", "a")],
            pos: pos, foot: foot, obstacleIDs: ["a", "b"])
        let f = try! #require(routes["f"]).curve
        let r = try! #require(routes["r"]).curve
        for t: Float in [0.25, 0.5, 0.75] {
            #expect(vlength(f.point(t) - r.point(t)) > 0.27)      // > laneWidth / 2
            #expect(vlength(f.point(t) - r.point(1 - t)) > 0.27)
        }
    }

    @Test("A long edge arcs clear of an intervening node")
    func liftsOverObstacle() {
        let pos: [String: SIMD3<Float>] = ["a": [-6, 0, 0], "b": [6, 0, 0], "mid": [0, 0, 0]]
        let foot: [String: Float] = ["a": 1.3, "b": 1.3, "mid": 1.3]
        let routes = GraphScene3DView.routeEdges3D(
            edges: [edge("f", "a", "b")], pos: pos, foot: foot, obstacleIDs: ["a", "b", "mid"])
        let c = try! #require(routes["f"]).curve
        let m = pos["mid"]!
        for p in c.samples(24) {
            let d = p - m
            #expect(vlength(d) > 0.6, "curve grazes the intervening 'mid' node")
        }
    }

    @Test("Self-loops are excluded from cross-edge routing (drawn as lists)")
    func selfLoopsExcluded() {
        let pos: [String: SIMD3<Float>] = ["a": [-4, 0, 0], "b": [4, 0, 0]]
        let foot: [String: Float] = ["a": 1.3, "b": 1.3]
        let routes = GraphScene3DView.routeEdges3D(
            edges: [edge("f", "a", "b"), edge("loop", "a", "a")],
            pos: pos, foot: foot, obstacleIDs: ["a", "b"])
        #expect(routes["f"] != nil)
        #expect(routes["loop"] == nil)     // self-loops are not routed here
    }
}
#endif
