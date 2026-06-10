import SwiftXState

// MARK: - Type-erased session over a running actor
//
// Each sample machine has its own Context type, so we can't store them in one array directly.
// `DemoSession` erases the context behind closures, exposing just what the UI needs: the event
// names, how to send one, the current state string, a generic context summary, and whether an
// event would currently cause a transition (for enabling/disabling buttons).

final class DemoSession {
    let events: [String]
    let send: (String) -> Void
    let state: () -> String
    let context: () -> String
    let canSend: (String) -> Bool

    init(
        events: [String],
        send: @escaping (String) -> Void,
        state: @escaping () -> String,
        context: @escaping () -> String,
        canSend: @escaping (String) -> Bool
    ) {
        self.events = events
        self.send = send
        self.state = state
        self.context = context
        self.canSend = canSend
    }
}

/// Builds a `DemoSession` from any machine, generically rendering its context via `Mirror`.
func session<C: Sendable & Equatable>(_ machine: StateMachine<C>) -> DemoSession {
    let actor = createActor(machine).start()
    return DemoSession(
        events: machine.events,
        send: { actor.send(Event($0)) },
        state: { actor.snapshot.value.description },
        context: {
            let fields = Mirror(reflecting: actor.snapshot.context).children.compactMap {
                child -> String? in
                guard let label = child.label else { return nil }
                return "\(label): \(child.value)"
            }
            return fields.isEmpty ? "—" : fields.joined(separator: "   ·   ")
        },
        canSend: { actor.snapshot.can(Event($0)) }
    )
}

// MARK: - A sample machine, ready to drop in the gallery

struct DemoSpec {
    let name: String
    let summary: String
    let make: () -> DemoSession
}

// MARK: - The sample machines

struct EmptyCtx: Sendable, Equatable {}

/// 1. Toggle — the simplest possible machine.
func makeToggle() -> DemoSession {
    session(createMachine(MachineConfig(
        id: "toggle",
        initial: "inactive",
        context: EmptyCtx(),
        states: [
            "inactive": StateNodeConfig(on: ["TOGGLE": .to("active")]),
            "active": StateNodeConfig(on: ["TOGGLE": .to("inactive")]),
        ]
    )))
}

/// 2. Traffic light — states + an `assign` action counting completed cycles.
func makeTrafficLight() -> DemoSession {
    struct Ctx: Sendable, Equatable { var cycles = 0 }
    return session(createMachine(MachineConfig(
        id: "trafficLight",
        initial: "go",
        context: Ctx(),
        states: [
            "go": StateNodeConfig(on: ["NEXT": .to("caution")]),
            "caution": StateNodeConfig(on: ["NEXT": .to("stop")]),
            "stop": StateNodeConfig(on: ["NEXT": .single(TransitionConfig(
                target: "go",
                actions: [assign { (c: inout Ctx, _) in c.cycles += 1 }]
            ))]),
        ]
    )))
}

/// 3. Vending machine — guards + context. DISPENSE only fires once you have 3 credits.
func makeVending() -> DemoSession {
    struct Ctx: Sendable, Equatable { var credits = 0 }
    return session(createMachine(MachineConfig(
        id: "vending",
        initial: "idle",
        context: Ctx(),
        states: [
            "idle": StateNodeConfig(on: [
                // Internal (no target) transition: just add a credit and stay put.
                "COIN": .single(TransitionConfig(actions: [assign { (c: inout Ctx, _) in c.credits += 1 }])),
                // Guarded: needs >= 3 credits; otherwise no transition (button stays disabled).
                "DISPENSE": .single(TransitionConfig(
                    target: "dispensing",
                    guard: .inline { $0.context.credits >= 3 },
                    actions: [assign { (c: inout Ctx, _) in c.credits -= 3 }]
                )),
            ]),
            "dispensing": StateNodeConfig(on: ["TAKE": .to("idle")]),
        ]
    )))
}

/// 4. Checkout — a linear multi-step flow you can walk forward and back.
func makeCheckout() -> DemoSession {
    session(createMachine(MachineConfig(
        id: "checkout",
        initial: "cart",
        context: EmptyCtx(),
        states: [
            "cart": StateNodeConfig(on: ["NEXT": .to("shipping")]),
            "shipping": StateNodeConfig(on: ["NEXT": .to("payment"), "BACK": .to("cart")]),
            "payment": StateNodeConfig(on: ["NEXT": .to("confirmed"), "BACK": .to("shipping")]),
            "confirmed": StateNodeConfig(on: ["RESTART": .to("cart")]),
        ]
    )))
}

/// 5. Fetch — the load/success/failure pattern with a retry guard (driven by manual events,
///    so it needs no timers or async — those behave differently under WebAssembly).
func makeFetch() -> DemoSession {
    struct Ctx: Sendable, Equatable { var retries = 0 }
    return session(createMachine(MachineConfig(
        id: "fetch",
        initial: "idle",
        context: Ctx(),
        states: [
            "idle": StateNodeConfig(on: ["FETCH": .to("loading")]),
            "loading": StateNodeConfig(on: [
                "RESOLVE": .to("success"),
                "REJECT": .multiple([
                    // Retry up to twice, then fail.
                    TransitionConfig(
                        target: "loading",
                        guard: .inline { $0.context.retries < 2 },
                        actions: [assign { (c: inout Ctx, _) in c.retries += 1 }]
                    ),
                    TransitionConfig(target: "failure"),
                ]),
            ]),
            "success": StateNodeConfig(on: ["FETCH": .to("loading")]),
            "failure": StateNodeConfig(on: ["RETRY": .to("loading")]),
        ]
    )))
}

@MainActor let samples: [DemoSpec] = [
    DemoSpec(name: "Toggle", summary: "The simplest machine: two states, one event.", make: makeToggle),
    DemoSpec(name: "Traffic light", summary: "States plus an assign action counting cycles.", make: makeTrafficLight),
    DemoSpec(name: "Vending machine", summary: "A guard + context: DISPENSE needs 3 credits.", make: makeVending),
    DemoSpec(name: "Checkout flow", summary: "A linear multi-step flow with forward/back.", make: makeCheckout),
    DemoSpec(name: "Fetch (manual)", summary: "Load / success / failure with a retry guard.", make: makeFetch),
]
