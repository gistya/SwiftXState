#if SWIFTXSTATE_GRAPH_UI
import Testing
import CoreGraphics
import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if canImport(SceneKit) && !os(watchOS)
import SceneKit
import Metal
#endif
@testable import SwiftXState
@testable import SwiftXStateGraph

// MARK: - Fixtures

/// A single flat compound machine whose five states are richly interconnected — the shape of the
/// `swiftbuilder.project` machine from the inspector screenshots (many edges, some parallel pairs, a
/// self-loop), which is exactly what defeated the old packed layout.
private func makeWebMachine() -> ResolvedMachine<Int> {
    func st(_ events: [String: String]) -> StateNodeConfig<Int> {
        StateNodeConfig(on: events.mapValues { .to($0) })
    }
    return createMachine(MachineConfig<Int>(
        id: "swiftbuilder", initial: "ready", context: 0,
        states: [
            "ready": st(["setPath": "loading", "refresh": "refreshing", "captureRevisions": "ready"]), // self-loop
            "loading": st(["setPath": "reloading", "refresh": "refreshing", "error": "error"]),
            "refreshing": st(["setBuildSubdir": "refreshing", "setPath": "reloading", "refresh": "ready"]),
            "reloading": st(["restore": "ready", "setCheckoutSchemeOverride": "error"]),
            "error": st(["captureRevisions": "error", "setPath": "reloading", "refresh": "ready"]),
        ]
    ))
}

/// Two rank-0 states (a, b) each pointing at a rank-1 state, wired so the *definition* order of the
/// rank-1 column (`p` before `q`) crosses the edges — but barycenter ordering should uncross it.
private func makeCrossingMachine() -> ResolvedMachine<Int> {
    createMachine(MachineConfig<Int>(
        id: "cm", initial: "a", context: 0,
        states: [
            "a": StateNodeConfig(on: ["E1": .to("q")]),   // top root → q
            "b": StateNodeConfig(on: ["E2": .to("p")]),   // bottom root → p
            "p": StateNodeConfig(),
            "q": StateNodeConfig(),
        ]
    ))
}

/// A typed-DSL machine that opts *out* of auto-layout.
private struct FixedMachine: StateMachine {
    typealias Context = Int
    typealias StateID = String
    typealias EventID = String
    var context: Int { 0 }
    var useAutoLayoutForInspection: Bool { false }
    var machine: some XStateMachine {
        State("a") { Transition(on: "go", to: "b") }.initial()
        State("b") {}
    }
}

private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

/// Counts geometric crossings between edge centre-lines (edges that share an endpoint are skipped —
/// they meet, they don't cross).
private func crossingCount(_ model: GraphModel, _ layout: GraphLayoutResult) -> Int {
    func center(_ id: String) -> CGPoint? { layout.frame(id).map { CGPoint(x: $0.midX, y: $0.midY) } }
    func ccw(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    func intersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        (ccw(a, c, d) * ccw(b, c, d) < 0) && (ccw(a, b, c) * ccw(a, b, d) < 0)
    }
    let edges = model.edges.filter { !$0.isSelfLoop }
    var count = 0
    for i in edges.indices {
        for j in (i + 1)..<edges.count {
            let e1 = edges[i], e2 = edges[j]
            if Set([e1.from, e1.to]).intersection([e2.from, e2.to]).isEmpty == false { continue }
            guard let a = center(e1.from), let b = center(e1.to),
                  let c = center(e2.from), let d = center(e2.to) else { continue }
            if intersect(a, b, c, d) { count += 1 }
        }
    }
    return count
}

@Suite("Inspector auto-layout")
struct AutoLayoutTests {

    // MARK: Flag data flow

    @Test("useAutoLayoutForInspection round-trips DSL → config → JSON → GraphModel")
    func flagRoundTrip() throws {
        let machine = FixedMachine().resolvedMachine(id: "fx")
        #expect(machine.config.useAutoLayoutForInspection == false)

        // Typed builder reads the config flag.
        #expect(GraphModelBuilder.build(from: machine).useAutoLayoutForInspection == false)

        // Exporter emits it at the root; definition builder reads it back.
        let json = try machine.definitionJSON()
        #expect(json.contains("useAutoLayoutForInspection"))
        let fromJSON = GraphModelBuilder.build(fromDefinitionJSON: json, machineID: "fx")
        #expect(fromJSON.useAutoLayoutForInspection == false)
    }

    @Test("Default machines omit the flag and default to true")
    func flagDefaultsTrue() throws {
        let machine = makeWebMachine()
        #expect(machine.config.useAutoLayoutForInspection == true)
        let json = try machine.definitionJSON()
        #expect(!json.contains("useAutoLayoutForInspection"))   // omitted when true — byte-compatible
        let model = GraphModelBuilder.build(fromDefinitionJSON: json, machineID: machine.id)
        #expect(model.useAutoLayoutForInspection == true)
    }

    // MARK: Layout invariants

    @Test("No two leaf nodes overlap under auto-layout")
    func leavesDoNotOverlap() {
        let model = GraphModelBuilder.build(from: makeWebMachine())
        let layout = GraphLayout.compute(model: model, style: .default)
        let leaves = model.nodes.filter { !$0.type.isContainer }
        #expect(leaves.count == 5)
        for i in leaves.indices {
            for j in (i + 1)..<leaves.count {
                let a = layout.frame(leaves[i].id)!
                let b = layout.frame(leaves[j].id)!
                #expect(!a.intersects(b), "\(leaves[i].id) overlaps \(leaves[j].id)")
            }
        }
    }

    @Test("Every leaf sits inside the root container")
    func rootContainsLeaves() {
        let model = GraphModelBuilder.build(from: makeWebMachine())
        let layout = GraphLayout.compute(model: model, style: .default)
        let root = layout.frame("swiftbuilder")!
        for leaf in model.nodes where !leaf.type.isContainer {
            #expect(root.contains(layout.frame(leaf.id)!), "root should contain \(leaf.id)")
        }
    }

    @Test("A region grows to contain a substate dragged outside it")
    func regionGrowsOnDrag() {
        let model = GraphModelBuilder.build(from: makeWebMachine())
        let dragged = "swiftbuilder.loading"
        // Without the refit pass the root frame (sized at measure time) would not contain this.
        let layout = GraphLayout.compute(
            model: model, style: .default,
            manualOffsets: [dragged: CGSize(width: 600, height: 500)]
        )
        let root = layout.frame("swiftbuilder")!
        let draggedFrame = layout.frame(dragged)!
        #expect(root.contains(draggedFrame))
    }

    @Test("Barycenter ordering + coordinate assignment yields an uncrossed layout")
    func barycenterUncrosses() {
        // Two roots each pointing at a rank-1 node: a good layered layout has zero crossings, so the
        // crossing-minimization pass must place the two rank-1 nodes on the matching side.
        let auto = GraphModelBuilder.build(from: makeCrossingMachine())
        let layoutAuto = GraphLayout.compute(model: auto, style: .default)
        #expect(crossingCount(auto, layoutAuto) == 0)
    }

    // MARK: Edge routing

    @Test("Auto-layout routes every non-self-loop edge; opting out routes none")
    func routesPresence() {
        let model = GraphModelBuilder.build(from: makeWebMachine())
        let layout = GraphLayout.compute(model: model, style: .default)
        let nonLoop = model.edges.filter { !$0.isSelfLoop }
        #expect(!nonLoop.isEmpty)
        #expect(layout.routes.count == nonLoop.count)
        for edge in nonLoop { #expect(layout.route(edge.id) != nil) }
        // Self-loops are drawn directly, not routed.
        for edge in model.edges where edge.isSelfLoop { #expect(layout.route(edge.id) == nil) }

        let off = GraphModel(machineID: model.machineID, rootID: model.rootID,
                             nodes: model.nodes, edges: model.edges, useAutoLayoutForInspection: false)
        #expect(GraphLayout.compute(model: off, style: .default).routes.isEmpty)
    }

    @Test("Parallel same-pair edges get distinct lanes, ports and label anchors")
    func parallelEdgesSeparate() {
        let model = GraphModelBuilder.build(from: makeWebMachine())
        let layout = GraphLayout.compute(model: model, style: .default)
        // reloading→error and error→reloading share the unordered pair {error, reloading}.
        let pair = Set(["swiftbuilder.error", "swiftbuilder.reloading"])
        let edges = model.edges.filter { Set([$0.from, $0.to]) == pair && !$0.isSelfLoop }
        #expect(edges.count == 2)
        let r0 = layout.route(edges[0].id)!
        let r1 = layout.route(edges[1].id)!
        #expect(r0.laneCount == 2 && r1.laneCount == 2)
        #expect(r0.laneIndex != r1.laneIndex)
        #expect(dist(r0.labelAnchor, r1.labelAnchor) > 1, "parallel labels should not coincide")
        #expect(dist(r0.points[0], r1.points[0]) > 0.5, "parallel edges should leave at distinct ports")
    }

    @Test("Edge colour is deterministic and label-derived")
    func stableEdgeColour() {
        let a = GraphEdge(id: "1", from: "a", to: "b", label: "setPath", kind: .event, isGuarded: false)
        let b = GraphEdge(id: "2", from: "x", to: "y", label: "setPath", kind: .event, isGuarded: false)
        let c = GraphEdge(id: "3", from: "a", to: "b", label: "refresh", kind: .event, isGuarded: false)
        #expect(a.stableHue == b.stableHue)         // same label → same hue, regardless of endpoints
        #expect(a.stableHue != c.stableHue)         // different label → different hue
        #expect(a.stableHue >= 0 && a.stableHue < 1)
    }

    @Test("A node with multiple self-loops widens so the fanned loops stay on its edge")
    func multiSelfLoopWidensNode() {
        // "hub" has three self-loops (a/b/c) plus one exit.
        let machine = createMachine(MachineConfig<Int>(
            id: "ml", initial: "hub", context: 0,
            states: [
                "hub": StateNodeConfig(on: ["a": .to("hub"), "b": .to("hub"), "c": .to("hub"), "go": .to("done")]),
                "done": StateNodeConfig(),
            ]
        ))
        let model = GraphModelBuilder.build(from: machine)
        let layout = GraphLayout.compute(model: model, style: .default)
        let hub = layout.frame("ml.hub")!
        let loops = model.edges.filter { $0.isSelfLoop && $0.from == "ml.hub" }.count
        #expect(loops == 3)
        // The outermost fanned loop centre sits at midX ± (loops-1)/2 · r · 2.4; it (plus the loop's own
        // half-width) must fall inside the node so no loop floats off the edge.
        let r = GraphStyle.default.selfLoopRadius
        let extreme = CGFloat(loops - 1) / 2 * r * 2.4 + r * 0.5
        #expect(hub.width / 2 >= extreme)
    }

    // MARK: Arrangement persistence

    @Test("Arrangement store round-trips node/edge offsets and clears")
    func arrangementStoreRoundTrips() {
        let mid = "arrangement-roundtrip-test"
        GraphArrangementStore.clear(mid)
        defer { GraphArrangementStore.clear(mid) }
        GraphArrangementStore.save(mid, nodes: ["n1": CGSize(width: 10, height: 20)], edges: ["e1": CGSize(width: -5, height: 7)])
        let loaded = GraphArrangementStore.load(mid)
        #expect(loaded.nodes["n1"] == CGSize(width: 10, height: 20))
        #expect(loaded.edges["e1"] == CGSize(width: -5, height: 7))
        GraphArrangementStore.clear(mid)
        let cleared = GraphArrangementStore.load(mid)
        #expect(cleared.nodes.isEmpty && cleared.edges.isEmpty)
    }

    @MainActor
    @Test("A fresh render model restores the saved arrangement for its machine")
    func renderModelRestoresArrangement() {
        let model = GraphModelBuilder.build(from: makeWebMachine())   // machineID "swiftbuilder"
        GraphArrangementStore.clear(model.machineID)
        defer { GraphArrangementStore.clear(model.machineID) }
        GraphArrangementStore.save(model.machineID, nodes: ["swiftbuilder.ready": CGSize(width: 40, height: 12)], edges: [:])
        // A brand-new render model (as the inspector builds on reopen) picks the arrangement back up.
        let render = GraphRenderModel(model: model)
        #expect(render.manualOffsets["swiftbuilder.ready"] == CGSize(width: 40, height: 12))
    }

    /// Renders the `swiftbuilder` graph to a PNG for eyeballing. Off by default (writes a file); run
    /// with `RENDER_SNAPSHOT=<dir> swift test --filter renderSnapshot`.
    @MainActor
    @Test("Render swiftbuilder 2D graph to PNG")
    func renderSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_SNAPSHOT"] else { return }
        let model = GraphModelBuilder.build(from: makeWebMachine())
        let layout = GraphLayout.compute(model: model, style: .dark)
        let bounds = layout.bounds
        let margin: CGFloat = 90
        let size = CGSize(width: bounds.width + margin * 2, height: bounds.height + margin * 2)

        let view = GraphCanvas(
            model: model, layout: layout, activeIDs: ["swiftbuilder.ready"], selectedID: nil,
            style: .dark, zoom: 1, pan: .zero, center: CGPoint(x: bounds.midX, y: bounds.midY)
        )
        .frame(width: size.width, height: size.height)
        .background(GraphStyle.dark.backgroundColor)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let cg = try #require(renderer.cgImage)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("swiftbuilder_2d.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    #if canImport(SceneKit) && canImport(AppKit) && !os(watchOS)
    /// Renders the decoupled 3D scene to a PNG (needs a GPU — skipped headless). Run with
    /// `RENDER_SNAPSHOT=<dir> swift test --filter render3DSnapshot`.
    @MainActor
    @Test("Render swiftbuilder 3D graph to PNG")
    func render3DSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_SNAPSHOT"] else { return }
        guard let device = MTLCreateSystemDefaultDevice() else { return }   // no GPU (headless) → skip
        let model = GraphModelBuilder.build(from: makeWebMachine())
        let layout = GraphLayout.compute(model: model, style: .dark)
        let view = GraphScene3DView(model: model, layout: layout, activeIDs: ["swiftbuilder.ready"],
                                    selectedID: nil, style: .dark, onSelect: nil)
        let scene = view.buildScene()
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: true)
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1500, height: 950), antialiasingMode: .multisampling4X)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("swiftbuilder_3d.png"))
    }
    #endif
}
#endif
