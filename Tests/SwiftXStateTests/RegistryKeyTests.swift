import Testing
@testable import SwiftXState

/// Typed actor registry via `RegistryKey<L>` — a string name carrying the actor's logic type, so
/// `system.actor(key)` returns a typed `Actor<L>`. The name is the identity; the type is the overlay.
@Suite("Typed actor registry (RegistryKey)")
struct RegistryKeyTests {
    private func svc() -> ResolvedMachine<Int> {
        createMachine(MachineConfig(id: "svc", initial: "idle", context: 0, states: ["idle": StateNodeConfig()]))
    }

    @Test("typed lookup resolves; same-typed keys stay distinct; missing → nil")
    func typedLookup() {
        let system = ActorSystem()
        let a = createActor(svc())
        let b = createActor(svc())                                   // same logic type as `a`
        system.set(RegistryKey<MachineLogic<Int>>("a"), actor: a)
        system.set(RegistryKey<MachineLogic<Int>>("b"), actor: b)    // same L, different key

        #expect(system.actor(RegistryKey<MachineLogic<Int>>("a")) === a)
        #expect(system.actor(RegistryKey<MachineLogic<Int>>("b")) === b)
        #expect(system.actor(RegistryKey<MachineLogic<Int>>("missing")) == nil)
    }

    @Test("a key with the wrong logic type does not resolve")
    func wrongType() {
        let system = ActorSystem()
        let a = createActor(svc())                                   // Actor<MachineLogic<Int>>
        system.set(RegistryKey<MachineLogic<Int>>("a"), actor: a)
        // Same name, different logic type → the downcast fails → nil.
        #expect(system.actor(RegistryKey<MachineLogic<String>>("a")) == nil)
    }
}
