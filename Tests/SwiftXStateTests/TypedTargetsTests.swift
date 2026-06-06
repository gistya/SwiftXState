import Testing
@testable import SwiftXState

// A machine whose state namespace is *generated* from its own declarations by `@MachineStates`,
// then used for compile-checked, typed targets.
private enum Lights {
    struct Next: StateEvent, Equatable { static let eventType = "NEXT" }

    @MachineStates("S")
    static let config = MachineConfig(
        id: "lights",
        initial: "green",
        context: EmptyContext(),
        states: [
            "green":  StateNodeConfig(on: transitions(on(Next.self, to: S.yellow))),
            "yellow": StateNodeConfig(on: transitions(on(Next.self, to: S.red))),
            "red":    StateNodeConfig(on: transitions(on(Next.self, to: S.green))),
        ]
    )
}

@Suite("Tier 2: @MachineStates typed targets")
struct TypedTargetsTests {

    @Test("generated enum has a case per state with #-absolute targets")
    func generatedEnum() {
        #expect(Lights.S.green.rawValue == "green")
        #expect(Lights.S.green.target == "#green")     // resolves via idMap machine-id fallback
        #expect(Lights.S.red.target == "#red")
    }

    @Test("typed targets drive real transitions")
    func typedTargetsDrive() {
        let actor = createActor(createMachine(Lights.config)).start()
        #expect(actor.snapshot.matches("green"))
        actor.send(Lights.Next())
        #expect(actor.snapshot.matches("yellow"))
        actor.send(Lights.Next())
        #expect(actor.snapshot.matches("red"))
        actor.send(Lights.Next())
        #expect(actor.snapshot.matches("green"))       // wrapped around — absolute targets resolved
    }
}
