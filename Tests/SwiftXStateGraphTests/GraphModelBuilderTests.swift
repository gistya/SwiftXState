#if SWIFTXSTATE_GRAPH_UI
import Testing
import CoreGraphics
@testable import SwiftXState
@testable import SwiftXStateGraph

/// A parallel machine with a compound region and a sibling region, mirroring the
/// shape of the chess machine (`game` + `castling`). This is exactly the structure
/// the old builder failed to walk — it returned only the root.
private func makeTrafficParallelMachine() -> StateMachine<Int> {
    createMachine(
        MachineConfig<Int>(
            id: "system",
            context: 0,
            states: [
                "light": StateNodeConfig(
                    initial: "green",
                    states: [
                        "green": StateNodeConfig(on: ["NEXT": .to("yellow")]),
                        "yellow": StateNodeConfig(on: ["NEXT": .to("red")]),
                        "red": StateNodeConfig(
                            on: ["NEXT": .to("green")],
                            always: [TransitionConfig(target: "green", guard: .inline { _ in false })]
                        ),
                    ]
                ),
                "alarm": StateNodeConfig(
                    initial: "off",
                    states: [
                        "off": StateNodeConfig(on: ["TRIGGER": .to("on")]),
                        "on": StateNodeConfig(type: .final),
                    ]
                ),
            ],
            type: .parallel
        )
    )
}

@Suite("GraphModelBuilder walks the real machine")
struct GraphModelBuilderTests {
    @Test("Builds every node from the live tree, not scaffolding")
    func buildsAllNodes() {
        let model = GraphModelBuilder.build(from: makeTrafficParallelMachine())

        // root + light{green,yellow,red} + alarm{off,on} = 8 nodes.
        #expect(model.nodes.count == 8)

        let ids = Set(model.nodes.map(\.id))
        #expect(ids.contains("system"))
        #expect(ids.contains("system.light"))
        #expect(ids.contains("system.light.green"))
        #expect(ids.contains("system.alarm.on"))

        // Root is parallel; light/alarm are compound; leaves are atomic; "on" is final.
        #expect(model.node("system")?.type == .parallel)
        #expect(model.node("system.light")?.type == .compound)
        #expect(model.node("system.light.green")?.type == .atomic)
        #expect(model.node("system.alarm.on")?.type == .final)
    }

    @Test("Relative paths match StateValue (drives highlighting)")
    func relativePaths() {
        let model = GraphModelBuilder.build(from: makeTrafficParallelMachine())
        #expect(model.node("system.light.green")?.relativePath == "light.green")
        #expect(model.node("system")?.relativePath == "")
        #expect(model.node("system.light.green")?.isInitialChild == true)
        #expect(model.node("system.light.red")?.isInitialChild == false)
    }

    @Test("Extracts transitions with event labels and kinds")
    func buildsEdges() {
        let model = GraphModelBuilder.build(from: makeTrafficParallelMachine())

        // Three NEXT transitions + one TRIGGER + one always = 5 edges.
        #expect(model.edges.count == 5)

        let next = model.edges.filter { $0.label == "NEXT" }
        #expect(next.count == 3)
        #expect(next.allSatisfy { $0.kind == .event })

        let always = model.edges.filter { $0.kind == .always }
        #expect(always.count == 1)
        #expect(always.first?.isGuarded == true)
        #expect(always.first?.from == "system.light.red")
        #expect(always.first?.to == "system.light.green")
    }

    @Test("Layout nests children inside their containers")
    func layoutContainment() {
        let model = GraphModelBuilder.build(from: makeTrafficParallelMachine())
        let layout = GraphLayout.compute(model: model, style: .default)

        let root = try! #require(layout.frame("system"))
        let green = try! #require(layout.frame("system.light.green"))
        let light = try! #require(layout.frame("system.light"))

        // Every leaf sits strictly inside its compound region, which sits inside root.
        #expect(light.contains(green))
        #expect(root.contains(light))
        #expect(layout.bounds.width > 0 && layout.bounds.height > 0)
    }

    @MainActor
    @Test("Active set updates as the actor transitions")
    func liveUpdates() {
        let machine = makeTrafficParallelMachine()
        let actor = createActor(machine)
        _ = actor.start(context: 0)
        // The view's live subscription pushes each new snapshot through `setActive`; here we
        // exercise that exact path directly.
        let render = GraphRenderModel(model: GraphModelBuilder.build(from: machine))
        render.setActive(stateValue: actor.snapshot.value)

        #expect(render.activeIDs.contains("system.light.green"))

        actor.send(Event("NEXT")) // green -> yellow
        render.setActive(stateValue: actor.snapshot.value)

        #expect(render.activeIDs.contains("system.light.yellow"))
        #expect(!render.activeIDs.contains("system.light.green"))
    }

    @MainActor
    @Test("Active set is computed from a live snapshot")
    func activeHighlighting() {
        let machine = makeTrafficParallelMachine()
        let actor = createActor(machine)
        _ = actor.start(context: 0)
        let render = GraphRenderModel(model: GraphModelBuilder.build(from: machine))
        render.setActive(stateValue: actor.snapshot.value)

        // Initial config: light.green + alarm.off both active in the parallel regions.
        #expect(render.activeIDs.contains("system.light.green"))
        #expect(render.activeIDs.contains("system.alarm.off"))
        #expect(!render.activeIDs.contains("system.light.red"))
    }

    @Test("Custom layout override arranges children in a grid")
    func customGridLayout() {
        // A 2×2 board of square regions that share no transitions.
        func square() -> StateNodeConfig<Int> {
            StateNodeConfig(initial: "empty", states: [
                "empty": StateNodeConfig(on: ["PUT": .to("occupied")]),
                "occupied": StateNodeConfig(on: ["CLEAR": .to("empty")]),
            ])
        }
        let machine = createMachine(MachineConfig<Int>(
            id: "m", initial: "board", context: 0,
            states: [
                "board": StateNodeConfig(type: .parallel, states: [
                    "s00": square(), "s01": square(), "s10": square(), "s11": square(),
                ]),
            ]
        ))

        let cell: CGFloat = 240
        var style = GraphStyle.default
        style.nodeLayoutOverride = { _, path in
            // path like "board.s01" -> row 0, col 1.
            let parts = path.split(separator: ".")
            guard parts.count == 2, parts[0] == "board", parts[1].hasPrefix("s") else { return nil }
            let digits = parts[1].dropFirst()
            guard digits.count == 2,
                  let row = Int(String(digits.first!)), let col = Int(String(digits.last!)) else { return nil }
            return CGPoint(x: CGFloat(col) * cell, y: CGFloat(row) * cell)
        }

        let model = GraphModelBuilder.build(from: machine)
        let layout = GraphLayout.compute(model: model, style: style)

        let s00 = layout.frame("m.board.s00")!
        let s01 = layout.frame("m.board.s01")!
        let s10 = layout.frame("m.board.s10")!
        let s11 = layout.frame("m.board.s11")!

        // Same row → same Y; same column → same X.
        #expect(abs(s00.midY - s01.midY) < 0.5)
        #expect(abs(s00.midX - s10.midX) < 0.5)
        // Grid ordering.
        #expect(s01.midX > s00.midX)
        #expect(s10.midY > s00.midY)
        #expect(s11.midX > s10.midX && s11.midY > s01.midY)
        // The two columns are one `cell` apart.
        #expect(abs((s01.midX - s00.midX) - cell) < 0.5)
    }

    @Test("Per-square states keep alphabetical order regardless of which is initial")
    func alphabeticalStateOrder() {
        func square(initiallyOccupied: Bool) -> StateNodeConfig<Int> {
            StateNodeConfig(initial: initiallyOccupied ? "occupied" : "empty", states: [
                "empty": StateNodeConfig(on: ["PUT": .to("occupied")]),
                "occupied": StateNodeConfig(on: ["CLEAR": .to("empty")]),
            ])
        }
        let machine = createMachine(MachineConfig<Int>(
            id: "board-inspector", context: 0,
            states: ["a1": square(initiallyOccupied: true), "a2": square(initiallyOccupied: false)],
            type: .parallel
        ))

        var style = GraphStyle.default
        style.nodeLayoutOverride = { _, path in
            let parts = path.split(separator: ".").map(String.init)
            if parts.count == 2 {
                return CGPoint(x: parts[1] == "empty" ? 0 : 240, y: 0) // alphabetical
            }
            if parts == ["a1"] { return CGPoint(x: 0, y: 0) }
            if parts == ["a2"] { return CGPoint(x: 0, y: 400) }
            return nil
        }

        let model = GraphModelBuilder.build(from: machine)
        let layout = GraphLayout.compute(model: model, style: style)

        // a1 starts occupied, a2 starts empty — but in both, `empty` is left of `occupied`.
        #expect(layout.frame("board-inspector.a1.empty")!.midX < layout.frame("board-inspector.a1.occupied")!.midX)
        #expect(layout.frame("board-inspector.a2.empty")!.midX < layout.frame("board-inspector.a2.occupied")!.midX)
    }

    @Test("Definition-JSON builder matches the typed builder")
    func definitionBuilderParity() throws {
        let machine = makeTrafficParallelMachine()
        let typed = GraphModelBuilder.build(from: machine)
        let json = try machine.definitionJSON()
        let fromJSON = GraphModelBuilder.build(fromDefinitionJSON: json, machineID: machine.id)

        // Same node set.
        #expect(Set(typed.nodes.map(\.id)) == Set(fromJSON.nodes.map(\.id)))
        // Same node types.
        for node in typed.nodes {
            #expect(fromJSON.node(node.id)?.type == node.type)
            #expect(fromJSON.node(node.id)?.relativePath == node.relativePath)
        }
        // Same transition endpoints (from -> to), ignoring synthetic edge ids.
        let typedEdges = Set(typed.edges.map { "\($0.from)->\($0.to)" })
        let jsonEdges = Set(fromJSON.edges.map { "\($0.from)->\($0.to)" })
        #expect(typedEdges == jsonEdges)
    }
}
#endif
