import Foundation
import SwiftXState

enum SampleDemoID: String, CaseIterable, Identifiable, Sendable {
    case toggle
    case counter
    case feedback
    case trafficLight
    case checkout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggle: return "Toggle"
        case .counter: return "Counter"
        case .feedback: return "Feedback"
        case .trafficLight: return "Traffic Light"
        case .checkout: return "Checkout Pipeline"
        }
    }

    var source: String {
        switch self {
        case .toggle: return "xstate/examples/toggle"
        case .counter: return "xstate/examples/7guis-1-counter-vue"
        case .feedback: return "xstate/templates/vanilla-ts"
        case .trafficLight: return "xstate docs / SwiftXState MachineTests"
        case .checkout: return "xstate workflow examples + SwiftXState invoke"
        }
    }
}

// MARK: - Toggle (examples/toggle)

enum ToggleMachineFactory {
    static func make() -> StateMachine<EmptyContext> {
        createMachine(MachineConfig(
            id: "toggle",
            initial: "inactive",
            context: EmptyContext(),
            states: [
                "inactive": StateNodeConfig(on: ["toggle": .to("active")]),
                "active": StateNodeConfig(on: ["toggle": .to("inactive")]),
            ]
        ))
    }
}

// MARK: - Counter (7guis-1-counter-vue)

struct CounterContext: Sendable, Equatable {
    var count: Int
}

enum CounterMachineFactory {
    static func make() -> StateMachine<CounterContext> {
        createMachine(MachineConfig(
            id: "Counter",
            initial: "ready",
            context: CounterContext(count: 0),
            states: [
                "ready": StateNodeConfig(on: [
                    "increase": .single(TransitionConfig(
                        target: "ready",
                        actions: [assign { context, _ in
                            context.count += 1
                        }]
                    )),
                ]),
            ]
        ))
    }
}

// MARK: - Feedback (templates/vanilla-ts)

struct FeedbackContext: Sendable, Equatable {
    var feedback: String
}

struct FeedbackUpdateEvent: Eventable, Equatable {
    let value: String
    var type: String { "feedback.update" }
}

enum FeedbackMachineFactory {
    static func make() -> StateMachine<FeedbackContext> {
        setup(
            guards: [
                "feedbackValid": { args in
                    !args.context.feedback.isEmpty
                },
            ]
        ).createMachine(MachineConfig(
            id: "feedback",
            initial: "prompt",
            context: FeedbackContext(feedback: ""),
            states: [
                "prompt": StateNodeConfig(on: [
                    "feedback.good": .to("thanks"),
                    "feedback.bad": .to("form"),
                ]),
                "form": StateNodeConfig(on: [
                    "feedback.update": .single(TransitionConfig(
                        actions: [assign { context, args in
                            if let event = args.event as? FeedbackUpdateEvent {
                                context.feedback = event.value
                            }
                        }]
                    )),
                    "back": .to("prompt"),
                    "submit": .single(TransitionConfig(
                        target: "thanks",
                        guard: .named("feedbackValid")
                    )),
                ]),
                "thanks": StateNodeConfig(),
                "closed": StateNodeConfig(on: [
                    "restart": .single(TransitionConfig(
                        target: "prompt",
                        actions: [assign { context, _ in
                            context.feedback = ""
                        }]
                    )),
                ]),
            ],
            on: [
                "close": .to("closed"),
            ]
        ))
    }
}

// MARK: - Traffic light (nested compound states)

enum TrafficLightMachineFactory {
    static func make() -> StateMachine<EmptyContext> {
        let pedestrianStates = StateNodeConfig<EmptyContext>(
            initial: "walk",
            states: [
                "walk": StateNodeConfig(on: ["PED_COUNTDOWN": .to("wait")]),
                "wait": StateNodeConfig(on: ["PED_COUNTDOWN": .to("stop")]),
                "stop": StateNodeConfig(),
            ]
        )

        return createMachine(MachineConfig(
            id: "trafficLight",
            initial: "green",
            context: EmptyContext(),
            states: [
                "green": StateNodeConfig(on: [
                    "TIMER": .to("yellow"),
                    "POWER_OUTAGE": .to("red"),
                ]),
                "yellow": StateNodeConfig(on: [
                    "TIMER": .to("red"),
                    "POWER_OUTAGE": .to("red"),
                ]),
                "red": StateNodeConfig(
                    initial: "walk",
                    states: pedestrianStates.states,
                    on: [
                        "TIMER": .to("green"),
                        "POWER_OUTAGE": .to("red"),
                    ]
                ),
            ]
        ))
    }
}

// MARK: - Checkout pipeline (status / output / error)

struct CheckoutContext: Sendable, Equatable {
    var orderId: String
    var amount: Double
    var cardValid: Bool
    var transactionId: String?
}

struct CheckoutResult: Sendable, Equatable {
    var orderId: String
    var amount: Double
    var transactionId: String
    var status: String
}

enum CheckoutValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidCard

    var description: String {
        switch self {
        case .invalidCard: return "Payment card declined"
        }
    }
}

enum CheckoutMachineFactory {
    static func make() -> StateMachine<CheckoutContext> {
        createMachine(MachineConfig(
            id: "checkout",
            initial: "idle",
            context: CheckoutContext(
                orderId: "ORD-1001",
                amount: 149.99,
                cardValid: true,
                transactionId: nil
            ),
            states: [
                "idle": StateNodeConfig(
                    on: [
                        "SUBMIT": .to("validating"),
                        "SUBMIT_DECLINED": .single(TransitionConfig(
                            target: "validating",
                            actions: [assign { context, _ in
                                context.cardValid = false
                            }]
                        )),
                    ],
                    tags: ["ready"],
                ),
                "validating": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "validatePayment",
                            src: fromTask { scope in
                                let valid = scope.input?.get(Bool.self) ?? true
                                guard valid else {
                                    throw CheckoutValidationError.invalidCard
                                }
                                try await Task.sleep(nanoseconds: 500_000_000)
                                return "validated"
                            },
                            input: { args in SendableValue(args.context.cardValid) },
                            onDone: .to("charging"),
                            onError: .to("rejected")
                        ),
                    ],
                    tags: ["processing"],
                ),
                "charging": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "chargePayment",
                            src: fromTask { _ in
                                try await Task.sleep(nanoseconds: 500_000_000)
                                return "txn-\(UUID().uuidString.prefix(8))"
                            },
                            onDone: .single(TransitionConfig(
                                target: "completed",
                                actions: [assign { context, args in
                                    if let event = args.event as? DoneActorEvent,
                                       let transactionId = event.output?.get(String.self)
                                    {
                                        context.transactionId = transactionId
                                    }
                                }]
                            )),
                            onError: .to("rejected")
                        ),
                    ],
                    tags: ["processing"],
                ),
                "completed": StateNodeConfig(
                    type: .final,
                    tags: ["success"],
                    output: { args in
                        SendableValue(
                            CheckoutResult(
                                orderId: args.context.orderId,
                                amount: args.context.amount,
                                transactionId: args.context.transactionId ?? "",
                                status: "completed"
                            )
                        )
                    }
                ),
                "rejected": StateNodeConfig(
                    type: .final,
                    tags: ["terminal-error", "failure"]
                ),
            ]
        ))
    }
}
