import Testing
@testable import SwiftXState

@Suite("Checkout pipeline")
struct CheckoutPipelineTests {
    @Test("successful checkout completes with output")
    func successPath() async {
        let machine = CheckoutMachineFactory.make()
        let reactor = createReactor(machine).start()
        reactor.send(Event("SUBMIT"))

        await reactor.waitForSnapshot { $0.status == .done }

        #expect(reactor.snapshot.status == .done)
        #expect(reactor.snapshot.matches("completed"))
        #expect(reactor.snapshot.output?.get(CheckoutResult.self)?.status == "completed")
        #expect(reactor.snapshot.error == nil)
    }

    @Test("declined card ends in error with message")
    func failurePath() async {
        let machine = CheckoutMachineFactory.make()
        let reactor = createReactor(machine).start()
        reactor.send(Event("SUBMIT_DECLINED"))

        await reactor.waitForSnapshot { $0.status == .error }

        #expect(reactor.snapshot.status == .error)
        #expect(reactor.snapshot.matches("rejected"))
        #expect(reactor.snapshot.output == nil)
        #expect(reactor.snapshot.error?.get(String.self) == "Payment card declined")
    }
}

private enum CheckoutMachineFactory {
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
                "idle": StateNodeConfig(on: [
                    "SUBMIT": .to("validating"),
                    "SUBMIT_DECLINED": .single(TransitionConfig(
                        target: "validating",
                        actions: [assign { context, _ in context.cardValid = false }]
                    )),
                ]),
                "validating": StateNodeConfig(
                    invoke: [
                        InvokeConfig(
                            id: "validatePayment",
                            src: fromTask { scope in
                                let valid = scope.input?.get(Bool.self) ?? true
                                guard valid else { throw CheckoutValidationError.invalidCard }
                                try await Task.sleep(nanoseconds: 100_000_000)
                                return "validated"
                            },
                            input: { args in SendableValue(args.context.cardValid) },
                            onDone: .to("completed"),
                            onError: .to("rejected")
                        ),
                    ]
                ),
                "completed": StateNodeConfig(
                    type: .final,
                    output: { args in
                        SendableValue(
                            CheckoutResult(
                                orderId: args.context.orderId,
                                amount: args.context.amount,
                                transactionId: "txn-test",
                                status: "completed"
                            )
                        )
                    }
                ),
                "rejected": StateNodeConfig(type: .final, tags: ["terminal-error"]),
            ]
        ))
    }
}

private struct CheckoutContext: Sendable, Equatable {
    var orderId: String
    var amount: Double
    var cardValid: Bool
    var transactionId: String?
}

private struct CheckoutResult: Sendable, Equatable {
    var orderId: String
    var amount: Double
    var transactionId: String
    var status: String
}

private enum CheckoutValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidCard

    var description: String { "Payment card declined" }
}
