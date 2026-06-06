import Testing
@testable import SwiftXState

@Suite("mapState")
struct MapStateTests {
    private struct CounterContext: Sendable, Equatable {
        var count: Int
    }

    @Test("collects leaf mapper for active atomic state")
    func leafMapper() {
        let machine = createMachine(MachineConfig(
            initial: "a",
            context: CounterContext(count: 0),
            states: [
                "a": StateNodeConfig(on: ["GO": .to("b")]),
                "b": StateNodeConfig(type: .atomic),
            ]
        ))

        let snapshot = createActor(machine).start().snapshot
        let mapper = StateMap<CounterContext, String>(
            states: [
                "a": .mapped { _ in "in-a" },
                "b": .mapped { _ in "in-b" },
            ]
        )

        #expect(snapshot.mapStateFirst(mapper) == "in-a")
    }

    @Test("returns parent and leaf mappers leaf-to-root")
    func ancestorChain() {
        let machine = createMachine(MachineConfig(
            initial: "parent",
            context: CounterContext(count: 0),
            states: [
                "parent": StateNodeConfig(
                    initial: "child",
                    states: [
                        "child": StateNodeConfig(type: .atomic),
                    ]
                ),
            ]
        ))

        let mapper = StateMap<CounterContext, String>(
            states: [
                "parent": .mapped(
                    { _ in "parent" },
                    states: [
                        "child": .mapped { _ in "child" },
                    ]
                ),
            ]
        )

        let snapshot = createActor(machine).start().snapshot
        let results = snapshot.mapState(mapper)

        #expect(results.map(\.result) == ["child", "parent"])
        #expect(results.map(\.statePath) == [["parent", "child"], ["parent"]])
    }

    @Test("parallel regions collect independent leaf mappers")
    func parallelRegions() {
        let machine = createMachine(MachineConfig(
            context: CounterContext(count: 0),
            states: [
                "foo": StateNodeConfig(
                    initial: "on",
                    states: ["on": StateNodeConfig(type: .atomic)]
                ),
                "bar": StateNodeConfig(
                    initial: "on",
                    states: ["on": StateNodeConfig(type: .atomic)]
                ),
            ],
            type: .parallel
        ))

        let mapper = StateMap<CounterContext, String>(
            states: [
                "foo": .mapped(
                    { _ in "foo" },
                    states: ["on": .mapped { _ in "foo-on" }]
                ),
                "bar": .mapped(
                    { _ in "bar" },
                    states: ["on": .mapped { _ in "bar-on" }]
                ),
            ]
        )

        let results = createActor(machine).start().snapshot.mapState(mapper)
        let mapped = Set(results.map { $0.result })
        #expect(mapped == ["foo-on", "bar-on", "foo", "bar"])
    }

    @Test("maps a derived view-state struct that reflects the active state")
    func derivedViewStateByPhase() {
        struct ViewState: Equatable {
            let label: String
            let isInteractive: Bool
        }

        let machine = createMachine(MachineConfig(
            initial: "playing",
            context: CounterContext(count: 0),
            states: [
                "playing": StateNodeConfig(on: ["PAUSE": .to("paused")]),
                "paused": StateNodeConfig(on: ["PLAY": .to("playing")]),
            ]
        ))

        let mapper = StateMap<CounterContext, ViewState>(
            states: [
                "playing": .mapped { _ in ViewState(label: "playing", isInteractive: true) },
                "paused": .mapped { _ in ViewState(label: "paused", isInteractive: false) },
            ]
        )

        let actor = createActor(machine).start()
        #expect(actor.snapshot.mapStateFirst(mapper) == ViewState(label: "playing", isInteractive: true))

        actor.send(Event("PAUSE"))
        #expect(actor.snapshot.mapStateFirst(mapper) == ViewState(label: "paused", isInteractive: false))
    }
}