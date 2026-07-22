import SwiftXState

// A small gallery of real SwiftXState machines, authored with the string-keyed
// config API (`createMachine(MachineConfig(...))`) — the Embedded-safe surface: no
// reflection, no Codable, closure-form `assign` and `.inline` guards only.
//
// Each machine is driven through the synchronous reducer (`MachineLogic.step`), so
// there is no async `Actor`, no scheduler, and no persistence layer to drag in.

// MARK: - Type-erased session

/// A running machine, erased over its concrete `Context`, so the engine can hold a
/// heterogeneous registry of them. Class-bound (reference existential) so it is
/// trivially fine under Embedded Swift.
protocol MachineSession: AnyObject {
    /// Current top-level state value, rendered as a string (e.g. `"red.walk"`).
    var stateName: String { get }
    /// Whether the machine has reached a top-level final state.
    var isDone: Bool { get }
    /// The current context, projected to JSON for the UI (hand-written per machine —
    /// no reflection).
    var contextJSON: JSONValue { get }
    /// Every event this machine understands, in display order.
    var eventNames: [String] { get }
    /// Whether sending `event` right now would cause a transition (honors guards).
    func canSend(_ event: String) -> Bool
    /// Re-create the initial snapshot.
    func reset()
    /// Advance the machine by one event.
    func send(_ event: String)
}

/// Concrete session over one `Context`. Holds the pure logic plus the current
/// snapshot value; `send`/`reset` just call the reducer.
final class GenericSession<Context: Sendable>: MachineSession {
    private let logic: MachineLogic<Context>
    private let events: [String]
    private let project: @Sendable (Context) -> JSONValue
    private var snapshot: MachineSnapshot<Context>

    init(
        machine: ResolvedMachine<Context>,
        events: [String],
        project: @escaping @Sendable (Context) -> JSONValue
    ) {
        self.logic = MachineLogic(machine: machine)
        self.events = events
        self.project = project
        self.snapshot = logic.initialState(input: nil)
    }

    var stateName: String { snapshot.value.description }
    var isDone: Bool { snapshot.status == .done }
    var contextJSON: JSONValue { project(snapshot.context) }
    var eventNames: [String] { events }
    func canSend(_ event: String) -> Bool { snapshot.can(Event(event)) }
    func reset() { snapshot = logic.initialState(input: nil) }
    func send(_ event: String) { snapshot = logic.step(snapshot, on: Event(event)) }
}

// MARK: - Contexts

struct ToggleContext: Sendable, Equatable { var toggles = 0 }
struct TrafficContext: Sendable, Equatable { var laps = 0 }
struct VendingContext: Sendable, Equatable { var credits = 0; var dispensed = 0 }
struct CounterContext: Sendable, Equatable { var value = 0 }
struct CrossingContext: Sendable, Equatable { var crossings = 0 }

// MARK: - Registry

enum Registry {
    /// Display order + metadata for the gallery. `states` is the flat list of notable
    /// top-level states the UI draws as a mini diagram (the active one is highlighted;
    /// for a compound state like `red`, the dotted value `red.walk` still matches).
    static let items: [(id: String, title: String, blurb: String, states: [String])] = [
        ("toggle", "Toggle", "The canonical two-state switch. Every flip bumps a context counter via an assign action.", ["inactive", "active"]),
        ("traffic", "Traffic Light", "green → yellow → red → green on NEXT, counting completed laps. PANIC jumps straight to red.", ["green", "yellow", "red"]),
        ("vending", "Vending Machine", "A guard in action: DISPENSE only fires once credits ≥ 3. COIN, DISPENSE, REFUND all mutate context.", ["idle", "collecting", "dispensing"]),
        ("counter", "Bounded Counter", "Guarded both ways — INC stops at 10, DEC stops at 0. RESET returns to zero.", ["counting"]),
        ("crossing", "Pedestrian Crossing", "A compound state: red nests walk / dontWalk. Note the dotted state value while red is active.", ["green", "yellow", "red"]),
    ]

    static func makeSession(_ id: String) -> (any MachineSession)? {
        switch id {
        case "toggle": return makeToggle()
        case "traffic": return makeTraffic()
        case "vending": return makeVending()
        case "counter": return makeCounter()
        case "crossing": return makeCrossing()
        default: return nil
        }
    }

    /// Static catalog JSON the UI reads once to build its tabs.
    static func catalogJSON() -> JSONValue {
        .array(items.map { item in
            .object([
                "id": .string(item.id),
                "title": .string(item.title),
                "blurb": .string(item.blurb),
                "states": .array(item.states.map { .string($0) }),
            ])
        })
    }
}

// MARK: - Machine builders

private func makeToggle() -> GenericSession<ToggleContext> {
    let bump = assign { (c: inout ToggleContext, _: ActionArgs<ToggleContext>) in c.toggles += 1 }
    let machine = createMachine(MachineConfig<ToggleContext>(
        id: "toggle",
        initial: "inactive",
        context: ToggleContext(),
        states: [
            "inactive": StateNodeConfig(on: [
                "TOGGLE": .single(TransitionConfig(target: "active", actions: [bump])),
            ]),
            "active": StateNodeConfig(on: [
                "TOGGLE": .single(TransitionConfig(target: "inactive", actions: [bump])),
            ]),
        ]
    ))
    return GenericSession(machine: machine, events: ["TOGGLE"]) { c in
        .object(["toggles": .number(Double(c.toggles))])
    }
}

private func makeTraffic() -> GenericSession<TrafficContext> {
    let countLap = assign { (c: inout TrafficContext, _: ActionArgs<TrafficContext>) in c.laps += 1 }
    let machine = createMachine(MachineConfig<TrafficContext>(
        id: "traffic",
        initial: "green",
        context: TrafficContext(),
        states: [
            "green": StateNodeConfig(on: [
                "NEXT": .to("yellow"),
                "PANIC": .to("red"),
            ]),
            "yellow": StateNodeConfig(on: [
                "NEXT": .to("red"),
                "PANIC": .to("red"),
            ]),
            "red": StateNodeConfig(on: [
                // Completing a red → green transition counts one full lap.
                "NEXT": .single(TransitionConfig(target: "green", actions: [countLap])),
            ]),
        ]
    ))
    return GenericSession(machine: machine, events: ["NEXT", "PANIC"]) { c in
        .object(["laps": .number(Double(c.laps))])
    }
}

private func makeVending() -> GenericSession<VendingContext> {
    let addCoin = assign { (c: inout VendingContext, _: ActionArgs<VendingContext>) in c.credits += 1 }
    let dispense = assign { (c: inout VendingContext, _: ActionArgs<VendingContext>) in
        c.credits -= 3
        c.dispensed += 1
    }
    let refund = assign { (c: inout VendingContext, _: ActionArgs<VendingContext>) in c.credits = 0 }
    let enoughCredits = GuardRef<VendingContext>.inline { $0.context.credits >= 3 }

    let machine = createMachine(MachineConfig<VendingContext>(
        id: "vending",
        initial: "idle",
        context: VendingContext(),
        states: [
            "idle": StateNodeConfig(on: [
                "COIN": .single(TransitionConfig(target: "collecting", actions: [addCoin])),
            ]),
            "collecting": StateNodeConfig(on: [
                "COIN": .single(TransitionConfig(target: "collecting", actions: [addCoin])),
                "DISPENSE": .single(TransitionConfig(
                    target: "dispensing",
                    guard: enoughCredits,
                    actions: [dispense]
                )),
                "REFUND": .single(TransitionConfig(target: "idle", actions: [refund])),
            ]),
            "dispensing": StateNodeConfig(on: [
                // Take the item; keep any remaining credits, going back to collecting
                // if some are left, otherwise idle.
                "TAKE": .multiple([
                    TransitionConfig(target: "collecting", guard: .inline { $0.context.credits > 0 }),
                    TransitionConfig(target: "idle"),
                ]),
            ]),
        ]
    ))
    return GenericSession(machine: machine, events: ["COIN", "DISPENSE", "REFUND", "TAKE"]) { c in
        .object([
            "credits": .number(Double(c.credits)),
            "dispensed": .number(Double(c.dispensed)),
        ])
    }
}

private func makeCounter() -> GenericSession<CounterContext> {
    let inc = assign { (c: inout CounterContext, _: ActionArgs<CounterContext>) in c.value += 1 }
    let dec = assign { (c: inout CounterContext, _: ActionArgs<CounterContext>) in c.value -= 1 }
    let zero = assign { (c: inout CounterContext, _: ActionArgs<CounterContext>) in c.value = 0 }
    let machine = createMachine(MachineConfig<CounterContext>(
        id: "counter",
        initial: "counting",
        context: CounterContext(),
        states: [
            // INC / DEC are action-only internal transitions (target: nil) — they
            // mutate context without leaving the state. Each is guarded so the value
            // stays within [0, 10].
            "counting": StateNodeConfig(on: [
                "INC": .single(TransitionConfig(
                    target: nil,
                    guard: .inline { $0.context.value < 10 },
                    actions: [inc]
                )),
                "DEC": .single(TransitionConfig(
                    target: nil,
                    guard: .inline { $0.context.value > 0 },
                    actions: [dec]
                )),
                "RESET": .single(TransitionConfig(target: nil, actions: [zero])),
            ]),
        ]
    ))
    return GenericSession(machine: machine, events: ["INC", "DEC", "RESET"]) { c in
        .object(["value": .number(Double(c.value))])
    }
}

private func makeCrossing() -> GenericSession<CrossingContext> {
    let countCrossing = assign { (c: inout CrossingContext, _: ActionArgs<CrossingContext>) in c.crossings += 1 }
    let machine = createMachine(MachineConfig<CrossingContext>(
        id: "crossing",
        initial: "green",
        context: CrossingContext(),
        states: [
            "green": StateNodeConfig(on: [
                "NEXT": .to("yellow"),
            ]),
            "yellow": StateNodeConfig(on: [
                "NEXT": .to("red"),
            ]),
            "red": StateNodeConfig(
                initial: "walk",
                states: [
                    "walk": StateNodeConfig(on: [
                        "PED": .to("dontWalk"),
                    ]),
                    "dontWalk": StateNodeConfig(),
                ],
                on: [
                    // From red (any substate), NEXT returns to the top-level green and
                    // records a completed crossing.
                    "NEXT": .single(TransitionConfig(target: "green", actions: [countCrossing])),
                ]
            ),
        ]
    ))
    return GenericSession(machine: machine, events: ["NEXT", "PED"]) { c in
        .object(["crossings": .number(Double(c.crossings))])
    }
}
