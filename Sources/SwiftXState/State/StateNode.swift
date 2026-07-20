
/// A node in the state machine graph.
public final class StateNode<Context: Sendable>: @unchecked Sendable {
    public let key: String
    public let id: String
    public let type: StateNodeType
    public let path: [String]
    public private(set) var states: [String: StateNode<Context>]
    public let parent: StateNode<Context>?
    // Embedded prohibits `weak`; see BackRef.swift for why a strong link is sound there.
    #if hasFeature(Embedded)
    var machine: ResolvedMachine<Context>?
    #else
    weak var machine: ResolvedMachine<Context>?
    #endif

    public let initial: String?
    public let entry: [ActionRef<Context>]
    public let exit: [ActionRef<Context>]
    public let tags: [String]
    public let meta: [String: SendableValue]?
    public let output: OutputResolver<Context>?
    public let description: String?
    public let history: HistoryType?
    /// Default transition target when no history is stored.
    public let historyTarget: String?
    public let order: Int

    public var transitions: [String: [ResolvedTransition<Context>]] = [:]
    public var always: [ResolvedTransition<Context>] = []
    var afterSchedules: [AfterSchedule] = []
    var invokeConfigs: [InvokeConfig<Context>] = []

    let config: StateNodeConfig<Context>
    private let machineId: String

    init(
        key: String,
        config: StateNodeConfig<Context>,
        parent: StateNode<Context>?,
        machine: ResolvedMachine<Context>? = nil,
        machineId: String? = nil
    ) {
        self.key = key
        self.config = config
        self.parent = parent
        self.machine = machine
        if let parent {
            self.path = key.isEmpty ? parent.path : parent.path + [key]
        } else {
            self.path = key.isEmpty ? [] : [key]
        }
        let resolvedMachineId = machine?.id
            ?? parent?.machineId
            ?? machineId
            ?? config.id
            ?? "(machine)"
        self.machineId = resolvedMachineId
        if let configId = config.id {
            self.id = configId
        } else if path.isEmpty {
            self.id = resolvedMachineId
        } else {
            self.id = "\(resolvedMachineId).\(path.joined(separator: "."))"
        }
        self.initial = config.initial
        self.entry = config.entry ?? []
        self.exit = config.exit ?? []
        self.tags = config.tags ?? []
        self.meta = config.meta
        self.output = config.output
        self.description = config.description
        self.history = config.history ?? (config.type == .history ? .shallow : nil)
        self.historyTarget = config.target
        self.order = machine?.idMap.count ?? parent?.machine?.idMap.count ?? 0

        if let configType = config.type {
            self.type = configType
        } else if let states = config.states, !states.isEmpty {
            self.type = .compound
        } else if config.history != nil {
            self.type = .history
        } else {
            self.type = .atomic
        }

        if type == .compound && config.initial == nil && config.states != nil && !config.states!.isEmpty {
            fatalError("No initial state specified for compound state node \"\(id)\"")
        }

        self.states = [:]
        if let statesConfig = config.states {
            for (childKey, childConfig) in statesConfig {
                states[childKey] = StateNode(
                    key: childKey,
                    config: childConfig,
                    parent: self,
                    machine: machine,
                    machineId: resolvedMachineId
                )
            }
        }

        machine?.idMap[id] = self

        if let on = config.on {
            for (eventType, input) in on {
                let configs = resolveTransitionConfigs(input)
                transitions[eventType, default: []].append(
                    contentsOf: configs.map { ResolvedTransition(config: $0, source: self) }
                )
            }
        }

        if let always = config.always {
            self.always = always.map { ResolvedTransition(config: $0, source: self) }
        }

        if let after = config.after {
            afterSchedules = processAfterConfig(after, stateNode: self)
        }

        if let invoke = config.invoke {
            invokeConfigs = invoke
            processInvokeConfig(invoke, stateNode: self)
        } else {
            invokeConfigs = []
        }

        if let onDone = config.onDone {
            processOnDoneConfig(onDone, stateNode: self)
        }
    }

    func eventTypes() -> Set<String> {
        var events = Set(transitions.keys.filter { !isWildcardEventDescriptor($0) })
        for child in states.values where child.type != .history {
            events.formUnion(child.eventTypes())
        }
        return events
    }

    func isAtomic() -> Bool {
        type == .atomic || type == .final
    }

    func bind(machine: ResolvedMachine<Context>) {
        self.machine = machine
        machine.idMap[id] = self
        for child in states.values {
            child.bind(machine: machine)
        }
    }
    
    private func processOnDoneConfig(
        _ onDone: TransitionInput<Context>,
        stateNode: StateNode<Context>
    ) {
        let eventType = createDoneStateEventType(stateNode.id)
        let transitions = resolveTransitionConfigs(onDone)
        stateNode.transitions[eventType, default: []].append(
            contentsOf: transitions.map { ResolvedTransition(config: $0, source: stateNode) }
        )
    }
    
    private func processInvokeConfig(
        _ invoke: [InvokeConfig<Context>],
        stateNode: StateNode<Context>
    ) {
        for config in invoke {
            if let onDone = config.onDone {
                let eventType = createDoneActorEventType(config.id)
                let transitions = resolveTransitionConfigs(onDone)
                stateNode.transitions[eventType, default: []].append(
                    contentsOf: transitions.map { ResolvedTransition(config: $0, source: stateNode) }
                )
            }

            if let onError = config.onError {
                let eventType = createErrorActorEventType(config.id)
                let transitions = resolveTransitionConfigs(onError)
                stateNode.transitions[eventType, default: []].append(
                    contentsOf: transitions.map { ResolvedTransition(config: $0, source: stateNode) }
                )
            }

            if let onSnapshot = config.onSnapshot {
                let eventType = createSnapshotActorEventType(config.id)
                let transitions = resolveTransitionConfigs(onSnapshot)
                stateNode.transitions[eventType, default: []].append(
                    contentsOf: transitions.map { ResolvedTransition(config: $0, source: stateNode) }
                )
            }
        }
    }
}

