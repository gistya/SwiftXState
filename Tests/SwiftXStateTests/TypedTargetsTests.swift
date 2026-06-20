import Testing
@testable import SwiftXState

// A machine whose state namespace is a hand-written `StateName` enum, used for compile-checked,
// typed targets. (One case per state; nested states use compound names with dotted raw values.)
private enum Lights {
    struct Next: StateEvent, Equatable { static let eventType = "NEXT" }

    enum S: String, StateName {
        case green
        case yellow
        case red
    }

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

@Suite("Tier 2: StateName typed targets")
struct TypedTargetsTests {

    @Test("StateName enum exposes #-absolute targets")
    func generatedEnum() {
        #expect(Lights.S.green.rawValue == "green")
        #expect(Lights.S.green.target == "#green")     // resolves via idMap machine-id fallback
        #expect(Lights.S.red.target == "#red")
    }

    @Test("typed targets drive real transitions")
    func typedTargetsDrive() async {
        let actor = await createActor(createMachine(Lights.config)).start()
        #expect(await actor.snapshot.matches("green"))
        await actor.send(Lights.Next())
        #expect(await actor.snapshot.matches("yellow"))
        await actor.send(Lights.Next())
        #expect(await actor.snapshot.matches("red"))
        await actor.send(Lights.Next())
        #expect(await actor.snapshot.matches("green"))       // wrapped around — absolute targets resolved
    }
}
