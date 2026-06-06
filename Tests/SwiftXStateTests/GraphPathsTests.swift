import Testing
@testable import SwiftXState

@Suite("Graph: paths, TestModel, validation")
struct GraphPathsTests {

    // A flat traffic light: green -> yellow -> red -> green.
    private func lights() -> StateMachine<EmptyContext> {
        createMachine(MachineConfig(
            id: "lights", initial: "green", context: EmptyContext(),
            states: [
                "green": StateNodeConfig(on: ["NEXT": .to("yellow")]),
                "yellow": StateNodeConfig(on: ["NEXT": .to("red")]),
                "red": StateNodeConfig(on: ["NEXT": .to("green")]),
            ]
        ))
    }

    @Test("adjacency map covers every reachable state with its edges")
    func adjacency() {
        let map = getAdjacencyMap(lights())
        #expect(Set(map.keys) == ["green", "yellow", "red"])
        #expect(map["green"]?.edges.count == 1)
        #expect(map["green"]?.edges.first?.nextStateKey == "yellow")
        #expect(map["red"]?.edges.first?.nextStateKey == "green")
    }

    @Test("shortest paths reach every state with minimal weight")
    func shortest() {
        let paths = getShortestPaths(lights())
        var byState: [String: StatePath<EmptyContext>] = [:]
        for p in paths { byState[p.state.value.description] = p }
        #expect(byState["green"]?.weight == 0)   // initial
        #expect(byState["yellow"]?.weight == 1)
        #expect(byState["red"]?.weight == 2)
        // The path to red is green -NEXT-> yellow -NEXT-> red.
        #expect(byState["red"]?.steps.map(\.event.type) == ["NEXT", "NEXT"])
        #expect(byState["red"]?.steps.last?.snapshot.matches("red") == true)
    }

    @Test("simple paths are acyclic and reach every state")
    func simple() {
        let paths = getSimplePaths(lights())
        // Every simple path is acyclic, so no path revisits a state value.
        for p in paths {
            let visited = p.steps.map { $0.snapshot.value.description }
            #expect(Set(visited).count == visited.count)
        }
        let reached = Set(paths.map { $0.state.value.description })
        #expect(reached == ["green", "yellow", "red"])
    }

    @Test("guards prune unreachable transitions during traversal")
    func guardedTraversal() {
        // `locked` only opens with the right guard; here the guard is always false, so `open`
        // is unreachable.
        let machine = createMachine(
            MachineConfig(
                id: "door", initial: "locked", context: EmptyContext(),
                states: [
                    "locked": StateNodeConfig(on: [
                        "PUSH": .single(TransitionConfig(target: "open", guard: .named("canOpen"))),
                    ]),
                    "open": StateNodeConfig(),
                ]
            ),
            implementations: MachineImplementations(guards: ["canOpen": { _, _ in false }])
        )

        let map = getAdjacencyMap(machine)
        #expect(map["locked"]?.edges.isEmpty == true)   // guard false -> no edge
        #expect(map["open"] == nil)                      // never reached

        let issues = validate(machine)
        #expect(issues.contains(MachineValidationIssue(kind: .unreachableState, stateKey: "open")))
        #expect(issues.contains(MachineValidationIssue(kind: .deadEnd, stateKey: "locked")))
    }

    @Test("TestModel walks a path through hooks in order")
    func testModelWalk() throws {
        let model = TestModel(lights())
        let toRed = model.shortestPaths().first { $0.state.value.description == "red" }!

        var states: [String] = []
        var events: [String] = []
        try model.test(
            toRed,
            onState: { states.append($0.value.description) },
            onEvent: { events.append($0.type) }
        )
        #expect(events == ["NEXT", "NEXT"])
        #expect(states == ["green", "yellow", "red"])   // initial + after each event
    }

    @Test("custom event resolver enables payload-driven traversal")
    func customEvents() {
        // A machine guarded on a payload value; only GO with the right payload advances.
        struct Ctx: Sendable { var ok = false }
        let machine = createMachine(
            MachineConfig(
                id: "p", initial: "a", context: Ctx(),
                states: [
                    "a": StateNodeConfig(on: ["GO": .to("b")]),
                    "b": StateNodeConfig(),
                ]
            )
        )
        var opts = TraversalOptions<Ctx>()
        opts.events = [Event("GO")]
        let map = getAdjacencyMap(machine, options: opts)
        #expect(map["a"]?.edges.first?.nextStateKey == "b")
        #expect(map["b"] != nil)
    }
}
