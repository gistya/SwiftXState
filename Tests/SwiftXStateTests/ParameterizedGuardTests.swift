import Testing
@testable import SwiftXState

private struct ThresholdContext: Sendable, Equatable {
    var value: Int
}

private struct MinAmountGuard: GuardSpec {
    struct Params: GuardParamValues, Equatable, Codable {
        let min: Int
    }

    static let name = "minAmount"
}

private struct RegionGuard: GuardSpec {
    struct Params: GuardParamValues, Equatable, Codable {
        let region: String
    }

    static let name = "inRegion"
}

private struct MarkGuard: ActionSpec {
    struct Params: GuardParamValues, Equatable, Codable {
        let label: String
    }

    static let name = "mark"
}

@Suite("Parameterized guards and actions")
struct ParameterizedGuardTests {
    @Test("typed guardRef selects transition using registered params")
    func typedGuardRef() {
        let machine = setup()
            .registerGuard(MinAmountGuard.self) { args, params in
                args.context.value >= params.min
            }
            .createMachine(MachineConfig(
                initial: "review",
                context: ThresholdContext(value: 0),
                states: [
                    "review": StateNodeConfig(on: [
                        "CHECK": .multiple([
                            TransitionConfig(
                                target: "approved",
                                guard: guardRef(MinAmountGuard.self, params: .init(min: 10))
                            ),
                            TransitionConfig(target: "rejected"),
                        ]),
                    ]),
                    "approved": StateNodeConfig(),
                    "rejected": StateNodeConfig(),
                ]
            ))

        let low = createActor(machine).start(context: ThresholdContext(value: 5))
        low.send(Event("CHECK"))
        #expect(low.snapshot.matches("rejected"))

        let high = createActor(machine).start(context: ThresholdContext(value: 25))
        high.send(Event("CHECK"))
        #expect(high.snapshot.matches("approved"))
    }

    @Test("dynamicGuard supports XState-style params objects")
    func dynamicGuard() {
        let machine = MachineSetup(
            guards: [
                "minAmount": { args, box in
                    guard case let .json(.object(object)) = box?.storage,
                          case let .number(min)? = object["min"] else {
                        return false
                    }
                    return Double(args.context.value) >= min
                },
            ]
        ).createMachine(MachineConfig(
            initial: "review",
            context: ThresholdContext(value: 0),
            states: [
                "review": StateNodeConfig(on: [
                    "CHECK": .single(TransitionConfig(
                        target: "approved",
                        guard: GuardRef<ThresholdContext>.dynamic(
                            "minAmount",
                            params: ["min": SendableValue(10)]
                        )
                    )),
                ]),
                "approved": StateNodeConfig(),
            ]
        ))

        let actor = createActor(machine).start(context: ThresholdContext(value: 12))
        actor.send(Event("CHECK"))
        #expect(actor.snapshot.matches("approved"))
    }

    @Test("registerAction runs with typed params")
    func typedActionRef() {
        final class Box: @unchecked Sendable {
            var labels: [String] = []
        }
        let box = Box()

        let machine = setup()
            .registerAction(MarkGuard.self) { _, params in
                box.labels.append(params.label)
            }
            .createMachine(MachineConfig(
                initial: "idle",
                context: ThresholdContext(value: 0),
                states: [
                    "idle": StateNodeConfig(on: [
                        "GO": .single(TransitionConfig(
                            target: "done",
                            actions: [actionRef(MarkGuard.self, params: .init(label: "ok"))]
                        )),
                    ]),
                    "done": StateNodeConfig(),
                ]
            ))

        let actor = createActor(machine).start()
        actor.send(Event("GO"))
        #expect(box.labels == ["ok"])
        #expect(actor.snapshot.matches("done"))
    }

    @Test("composite guards compose with parameterized refs")
    func compositeParameterizedGuard() {
        let machine = setup()
            .registerGuard(MinAmountGuard.self) { args, params in
                args.context.value >= params.min
            }
            .createMachine(MachineConfig(
                initial: "review",
                context: ThresholdContext(value: 0),
                states: [
                    "review": StateNodeConfig(on: [
                        "CHECK": .single(TransitionConfig(
                            target: "approved",
                            guard: and(
                                guardRef(MinAmountGuard.self, params: .init(min: 5)),
                                .inline { $0.context.value < 100 }
                            )
                        )),
                    ]),
                    "approved": StateNodeConfig(),
                ]
            ))

        let actor = createActor(machine).start(context: ThresholdContext(value: 12))
        actor.send(Event("CHECK"))
        #expect(actor.snapshot.matches("approved"))
    }

    @Test("definition JSON exports parameterized guard shape")
    func guardDefinitionJSON() throws {
        let machine = setup()
            .registerGuard(MinAmountGuard.self) { _, _ in true }
            .createMachine(MachineConfig(
                initial: "review",
                context: ThresholdContext(value: 0),
                states: [
                    "review": StateNodeConfig(on: [
                        "CHECK": .single(TransitionConfig(
                            target: "approved",
                            guard: guardRef(MinAmountGuard.self, params: .init(min: 10))
                        )),
                    ]),
                    "approved": StateNodeConfig(),
                ]
            ))

        let json = try machine.definitionJSON()
        #expect(json.contains("\"type\":\"minAmount\""))
        #expect(json.contains("\"params\""))
        #expect(json.contains("\"min\""))
    }

    @Test("definition JSON exports string-typed guard params")
    func stringParamGuardJSON() throws {
        let machine = setup()
            .registerGuard(RegionGuard.self) { _, _ in true }
            .createMachine(MachineConfig(
                initial: "review",
                context: ThresholdContext(value: 0),
                states: [
                    "review": StateNodeConfig(on: [
                        "CHECK": .single(TransitionConfig(
                            target: "approved",
                            guard: guardRef(RegionGuard.self, params: .init(region: "north"))
                        )),
                    ]),
                    "approved": StateNodeConfig(),
                ]
            ))

        let json = try machine.definitionJSON()
        #expect(json.contains("\"type\":\"inRegion\""))
        #expect(json.contains("\"region\""))
        #expect(json.contains("north"))
    }
}