import Foundation

/// A JSON-compatible value for machine definition export.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public static func encode(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MachineDefinitionError.encodingFailed
        }
        return text
    }
}

public enum MachineDefinitionError: Error, Sendable, Equatable {
    case encodingFailed
}

extension StateMachine {
    /// Exports this machine as an XState-compatible JSON definition string.
    public func definitionJSON() throws -> String {
        try MachineDefinitionExporter.export(self)
    }
}

enum MachineDefinitionExporter {
    static func export<Context: Sendable>(_ machine: StateMachine<Context>) throws -> String {
        let document = exportNode(machine.root, machineId: machine.id)
        return try JSONValue.encode(document)
    }

    static func exportNode<Context: Sendable>(
        _ node: StateNode<Context>,
        machineId: String
    ) -> JSONValue {
        var object: [String: JSONValue] = [:]

        if node.path.isEmpty {
            if machineId != "(machine)" {
                object["id"] = .string(machineId)
            }
        } else if node.id != "\(machineId).\(node.path.joined(separator: "."))" {
            object["id"] = .string(node.id)
        }

        if let initial = node.initial {
            object["initial"] = .string(initial)
        }

        switch node.type {
        case .parallel:
            object["type"] = .string("parallel")
        case .final:
            object["type"] = .string("final")
        case .history:
            object["type"] = .string("history")
            if let history = node.history {
                object["history"] = .string(history == .shallow ? "shallow" : "deep")
            }
            if let target = node.historyTarget {
                object["target"] = .string(target)
            }
        case .atomic, .compound:
            break
        }

        if !node.states.isEmpty {
            var states: [String: JSONValue] = [:]
            for (key, child) in node.states.sorted(by: { $0.key < $1.key }) {
                states[key] = exportNode(child, machineId: machineId)
            }
            object["states"] = .object(states)
        }

        if !node.transitions.isEmpty {
            var on: [String: JSONValue] = [:]
            for (eventType, transitions) in node.transitions.sorted(by: { $0.key < $1.key }) {
                if eventType.hasPrefix("xstate.after.") || eventType.hasPrefix("xstate.done.") ||
                    eventType.hasPrefix("xstate.error.") || eventType.hasPrefix("xstate.snapshot.")
                {
                    continue
                }
                on[eventType] = serializeTransitions(transitions.map(\.config), from: node)
            }
            if !on.isEmpty {
                object["on"] = .object(on)
            }
        }

        if !node.always.isEmpty {
            object["always"] = .array(node.always.map { serializeTransition($0.config, from: node) })
        }

        if let afterConfig = node.config.after, !afterConfig.isEmpty {
            var after: [String: JSONValue] = [:]
            for (delay, input) in afterConfig.sorted(by: { $0.key < $1.key }) {
                after[delay] = serializeTransitionInput(input, from: node)
            }
            object["after"] = .object(after)
        }

        if let onDone = node.config.onDone {
            object["onDone"] = serializeTransitionInput(onDone, from: node)
        }

        if !node.invokeConfigs.isEmpty {
            object["invoke"] = .array(node.invokeConfigs.map { serializeInvoke($0, from: node) })
        }

        if !node.entry.isEmpty {
            object["entry"] = .array(node.entry.map(serializeAction))
        }

        if !node.exit.isEmpty {
            object["exit"] = .array(node.exit.map(serializeAction))
        }

        if !node.tags.isEmpty {
            object["tags"] = .array(node.tags.sorted().map(JSONValue.string))
        }

        if let meta = node.meta, !meta.isEmpty {
            var metaObject: [String: JSONValue] = [:]
            for (key, value) in meta.sorted(by: { $0.key < $1.key }) {
                metaObject[key] = InspectJSONEncoder.encode(value)
            }
            object["meta"] = .object(metaObject)
        }

        if let description = node.description {
            object["description"] = .string(description)
        }

        return .object(object)
    }

    static func serializeTransitionInput<Context: Sendable>(
        _ input: TransitionInput<Context>,
        from source: StateNode<Context>
    ) -> JSONValue {
        switch input {
        case let .target(target):
            return .string(exportTarget(target, from: source))
        case let .single(config):
            return serializeTransition(config, from: source)
        case let .multiple(configs):
            return .array(configs.map { serializeTransition($0, from: source) })
        }
    }

    static func serializeTransitions<Context: Sendable>(
        _ configs: [TransitionConfig<Context>],
        from source: StateNode<Context>
    ) -> JSONValue {
        if configs.count == 1 {
            return serializeTransition(configs[0], from: source)
        }
        return .array(configs.map { serializeTransition($0, from: source) })
    }

    static func serializeTransition<Context: Sendable>(
        _ config: TransitionConfig<Context>,
        from source: StateNode<Context>
    ) -> JSONValue {
        var object: [String: JSONValue] = [:]

        if let targets = config.targets, !targets.isEmpty {
            object["target"] = .array(targets.map { .string(exportTarget($0, from: source)) })
        } else if let target = config.target {
            object["target"] = .string(exportTarget(target, from: source))
        }

        if let guardRef = config.guardRef {
            object["guard"] = serializeGuard(guardRef)
        }

        if let actions = config.actions, !actions.isEmpty {
            object["actions"] = .array(actions.map(serializeAction))
        }

        if let reenter = config.reenter {
            object["reenter"] = .bool(reenter)
        }

        if let description = config.description {
            object["description"] = .string(description)
        }

        if object.isEmpty {
            return .null
        }

        if object.count == 1, let target = object["target"] {
            return target
        }

        return .object(object)
    }

    /// Exports transition targets in a shape XState and Stately Inspector can resolve.
    static func exportTarget<Context: Sendable>(
        _ target: String,
        from source: StateNode<Context>
    ) -> String {
        if target.hasPrefix("#") || target.hasPrefix(".") {
            return target
        }

        let firstSegment = target.split(separator: ".").first.map(String.init) ?? target
        if source.states[firstSegment] != nil {
            return target
        }
        if let parent = source.parent, parent.states[firstSegment] != nil {
            return target
        }

        guard let machine = source.machine,
              let resolved = machine.resolveTarget(target, from: source).first else {
            let machineId = source.machine?.id ?? source.id
            return "#\(machineId).\(target)"
        }
        return "#\(resolved.id)"
    }

    static func serializeGuard<Context: Sendable>(_ guardRef: GuardRef<Context>) -> JSONValue {
        switch guardRef {
        case let .named(name):
            return .string(name)
        case let .parameterized(name, params):
            return serializeParameterizedReference(name: name, params: params)
        case .inline:
            return .string("xstate.inline")
        case let .composite(composite):
            return serializeCompositeGuard(composite)
        }
    }

    static func serializeCompositeGuard<Context: Sendable>(
        _ composite: CompositeGuard<Context>
    ) -> JSONValue {
        switch composite {
        case let .and(guards):
            return .object(["and": .array(guards.map(serializeGuard))])
        case let .or(guards):
            return .object(["or": .array(guards.map(serializeGuard))])
        case let .not(negatedGuard):
            return .object(["not": serializeGuard(negatedGuard)])
        case let .stateIn(state):
            return .object(["stateIn": .string(state)])
        }
    }

    static func serializeAction<Context: Sendable>(_ action: ActionRef<Context>) -> JSONValue {
        switch action {
        case let .named(name):
            return .string(name)
        case let .parameterized(name, params):
            return serializeParameterizedReference(name: name, params: params)
        case .assign:
            return .string("xstate.assign")
        case .inline:
            return .string("xstate.inline")
        case .spawn:
            return .string("xstate.spawnChild")
        case .stopChild:
            return .string("xstate.stopChild")
        case .forwardTo:
            return .string("xstate.forwardTo")
        case .sendTo:
            return .string("xstate.sendTo")
        case .sendParent:
            return .string("xstate.sendParent")
        case .raise:
            return .string("xstate.raise")
        case .cancel:
            return .string("xstate.cancel")
        case .enqueueActions:
            return .string("xstate.enqueueActions")
        case .log:
            return .string("xstate.log")
        case .emit:
            return .string("xstate.emit")
        }
    }

    static func serializeInvoke<Context: Sendable>(
        _ config: InvokeConfig<Context>,
        from source: StateNode<Context>
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(config.id),
            "src": serializeActorSource(config.src),
        ]

        if let systemId = config.systemId {
            object["systemId"] = .string(systemId)
        }

        if let onDone = config.onDone {
            object["onDone"] = serializeTransitionInput(onDone, from: source)
        }

        if let onError = config.onError {
            object["onError"] = serializeTransitionInput(onError, from: source)
        }

        if let onSnapshot = config.onSnapshot {
            object["onSnapshot"] = serializeTransitionInput(onSnapshot, from: source)
        }

        if config.opaqueRestorePolicy != .restart {
            object["opaqueRestorePolicy"] = .string(config.opaqueRestorePolicy.rawValue)
        }

        return .object(object)
    }

    static func serializeActorSource(_ source: ActorSource) -> JSONValue {
        switch source {
        case let .named(name):
            return .string(name)
        case .machine:
            return .string("xstate.machine")
        case .task:
            return .string("swift.task")
        case .callback:
            return .string("swift.callback")
        case .taskGroup:
            return .string("swift.taskGroup")
        case .transition:
            return .string("xstate.transition")
        case .observable:
            return .string("xstate.observable")
        case .store:
            return .string("xstate.store")
        }
    }
}

extension StateValue {
    public func toJSONValue() -> JSONValue {
        switch self {
        case let .atomic(value):
            return .string(value)
        case let .compound(values):
            var object: [String: JSONValue] = [:]
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                object[key] = value.toJSONValue()
            }
            return .object(object)
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}