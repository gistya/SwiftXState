import Foundation

// MARK: - State Node Set Operations

func getAllStateNodes<Context: Sendable>(_ nodes: StateNodeSet<Context>) -> StateNodeSet<Context> {
    var nodeSet = nodes

    for node in nodes {
        if node.type == .compound {
            let children = getAdjacencyList(nodeSet)[ObjectIdentifier(node)] ?? []
            if children.isEmpty, let initial = node.initial, let child = node.states[initial] {
                for sn in getInitialStateNodesWithAncestors(child) {
                    nodeSet.insert(sn)
                }
            }
        } else if node.type == .parallel {
            for child in node.states.values where child.type != .history {
                if !nodeSet.contains(child) {
                    for sn in getInitialStateNodesWithAncestors(child) {
                        nodeSet.insert(sn)
                    }
                }
            }
        }
    }

    for node in nodeSet {
        var parent = node.parent
        while let p = parent {
            nodeSet.insert(p)
            parent = p.parent
        }
    }

    return nodeSet
}

func getInitialStateNodesWithAncestors<Context: Sendable>(
    _ node: StateNode<Context>
) -> [StateNode<Context>] {
    var nodes = [node]
    if node.type == .parallel {
        for child in node.states.values where child.type != .history {
            nodes.append(contentsOf: getInitialStateNodesWithAncestors(child))
        }
    } else if let initial = node.initial, let child = node.states[initial] {
        nodes.append(contentsOf: getInitialStateNodesWithAncestors(child))
    }
    return nodes
}

func getAdjacencyList<Context: Sendable>(_ nodes: StateNodeSet<Context>) -> [ObjectIdentifier: [StateNode<Context>]] {
    var adj: [ObjectIdentifier: [StateNode<Context>]] = [:]
    for node in nodes {
        let id = ObjectIdentifier(node)
        adj[id, default: []] = adj[id] ?? []
        if let parent = node.parent {
            adj[ObjectIdentifier(parent), default: []].append(node)
        }
    }
    return adj
}

func getStateValue<Context: Sendable>(
    root: StateNode<Context>,
    nodes: StateNodeSet<Context>
) -> StateValue {
    let allNodes = getAllStateNodes(nodes)
    return getValueFromAdj(base: root, adj: getAdjacencyList(allNodes))
}

private func getValueFromAdj<Context: Sendable>(
    base: StateNode<Context>,
    adj: [ObjectIdentifier: [StateNode<Context>]]
) -> StateValue {
    guard let children = adj[ObjectIdentifier(base)], !children.isEmpty else {
        return .compound([:])
    }

    if base.type == .compound, children.count == 1, let child = children.first, child.isAtomic() {
        return .atomic(child.key)
    }

    var stateValue: [String: StateValue] = [:]
    for child in children.sorted(by: { $0.order < $1.order }) {
        stateValue[child.key] = getValueFromAdj(base: child, adj: adj)
    }
    return .compound(stateValue)
}

func getTags<Context: Sendable>(from nodes: StateNodeSet<Context>) -> Set<String> {
    var tags = Set<String>()
    for node in nodes {
        tags.formUnion(node.tags)
    }
    return tags
}

func getProperAncestors<Context: Sendable>(
    _ stateNode: StateNode<Context>,
    to target: StateNode<Context>?
) -> [StateNode<Context>] {
    var ancestors: [StateNode<Context>] = []
    if target === stateNode { return ancestors }
    var current = stateNode.parent
    while let node = current, node !== target {
        ancestors.append(node)
        current = node.parent
    }
    return ancestors
}

// MARK: - History

func isHistoryNode<Context: Sendable>(_ node: StateNode<Context>) -> Bool {
    node.type == .history
}

func getHistoryNodes<Context: Sendable>(for stateNode: StateNode<Context>) -> [StateNode<Context>] {
    stateNode.states.values.filter { $0.type == .history }
}

func resolveHistoryDefaultTransition<Context: Sendable>(
    _ historyNode: StateNode<Context>
) -> [StateNode<Context>] {
    guard let machine = historyNode.machine, let parent = historyNode.parent else {
        return []
    }

    if let targetPath = historyNode.historyTarget {
        return machine.resolveTarget(targetPath, from: historyNode)
    }

    if let initialKey = parent.initial, let initialChild = parent.states[initialKey] {
        return machine.getInitialStateNodes(initialChild)
    }

    return []
}

func getEffectiveTargetStates<Context: Sendable>(
    _ rawTargets: [StateNode<Context>],
    historyValue: HistoryValue<Context>
) -> [StateNode<Context>] {
    var result: [StateNode<Context>] = []

    for target in rawTargets {
        if isHistoryNode(target) {
            if let stored = historyValue.nodes(for: target.id), !stored.isEmpty {
                result.append(contentsOf: stored)
            } else {
                result.append(contentsOf: resolveHistoryDefaultTransition(target))
            }
        } else {
            result.append(target)
        }
    }

    return result
}

func recordHistoryOnExit<Context: Sendable>(
    exitingNodes: StateNodeSet<Context>,
    activeNodes: StateNodeSet<Context>,
    historyValue: inout HistoryValue<Context>
) {
    for exitNode in exitingNodes {
        for historyNode in getHistoryNodes(for: exitNode) {
            let recorded: [StateNode<Context>]
            if historyNode.history == .deep {
                recorded = activeNodes.filter { node in
                    node.isAtomic() && isDescendant(node, of: exitNode)
                }
            } else {
                recorded = activeNodes.filter { $0.parent === exitNode }
            }
            historyValue.set(recorded, for: historyNode.id)
        }
    }
}

func resolveInitialStateNodes<Context: Sendable>(
    _ initialNode: StateNode<Context>,
    historyValue: HistoryValue<Context>
) -> StateNodeSet<Context> {
    if isHistoryNode(initialNode) {
        let nodes = StateNodeSet(getEffectiveTargetStates([initialNode], historyValue: historyValue))
        return getAllStateNodes(nodes)
    }

    var nodes = StateNodeSet(initialNode.machine?.getInitialStateNodes(initialNode) ?? [initialNode])
    nodes.insert(initialNode)
    return getAllStateNodes(nodes)
}

// MARK: - Transition Selection

enum EventDescriptorMatch: Sendable {
    case exact
    case partialWildcard
    case fullWildcard
}

func eventDescriptorMatch(eventType: String, descriptor: String) -> EventDescriptorMatch? {
    if descriptor == eventType {
        return .exact
    }

    if descriptor == wildcardEventDescriptor {
        return .fullWildcard
    }

    if descriptor.hasSuffix(".*") {
        let prefix = String(descriptor.dropLast(2))
        if eventType == prefix || eventType.hasPrefix(prefix + ".") {
            return .partialWildcard
        }
    }

    return nil
}

func isWildcardEventDescriptor(_ descriptor: String) -> Bool {
    descriptor == wildcardEventDescriptor || descriptor.hasSuffix(".*")
}

func enabledTransitions<Context: Sendable>(
    _ transitions: [ResolvedTransition<Context>],
    snapshot: MachineSnapshot<Context>,
    event: any Eventable
) -> [ResolvedTransition<Context>] {
    transitions.filter { transition in
        let args = ActionArgs(context: snapshot.context, event: event)
        return evaluateGuard(
            transition.config.guardRef,
            args: args,
            implementations: snapshot.machine.implementations,
            stateValue: snapshot.value
        )
    }
}

func selectTransitionsForNode<Context: Sendable>(
    _ node: StateNode<Context>,
    event: any Eventable,
    snapshot: MachineSnapshot<Context>
) -> [ResolvedTransition<Context>] {
    if let exact = node.transitions[event.type] {
        let enabled = enabledTransitions(exact, snapshot: snapshot, event: event)
        if !enabled.isEmpty {
            return enabled
        }
    }

    let partialDescriptors = node.transitions.keys
        .filter { $0.hasSuffix(".*") }
        .sorted()

    for descriptor in partialDescriptors {
        guard eventDescriptorMatch(eventType: event.type, descriptor: descriptor) == .partialWildcard else {
            continue
        }
        let enabled = enabledTransitions(
            node.transitions[descriptor] ?? [],
            snapshot: snapshot,
            event: event
        )
        if !enabled.isEmpty {
            return enabled
        }
    }

    return []
}

func transitionSelectionKey<Context: Sendable>(_ transition: ResolvedTransition<Context>) -> String {
    let targetKey = transition.config.targets?.joined(separator: "|") ?? transition.config.target ?? ""
    return "\(transition.source.id)|\(targetKey)"
}

func dedupeTransitions<Context: Sendable>(
    _ transitions: [ResolvedTransition<Context>]
) -> [ResolvedTransition<Context>] {
    var seen = Set<String>()
    var result: [ResolvedTransition<Context>] = []
    for transition in transitions {
        let key = transitionSelectionKey(transition)
        if seen.insert(key).inserted {
            result.append(transition)
        }
    }
    return result
}

func selectTransitionsFromAtomicStates<Context: Sendable>(
    event: any Eventable,
    snapshot: MachineSnapshot<Context>,
    wildcardFallback: Bool
) -> [ResolvedTransition<Context>] {
    let atomicStates = snapshot._nodes.filter { $0.isAtomic() || $0.type == .final }
    var transitions: [ResolvedTransition<Context>] = []

    for leaf in atomicStates {
        let chain = [leaf] + getProperAncestors(leaf, to: nil)
        for node in chain {
            if wildcardFallback {
                guard let wildcard = node.transitions[wildcardEventDescriptor] else { continue }
                let enabled = enabledTransitions(wildcard, snapshot: snapshot, event: event)
                if !enabled.isEmpty {
                    transitions.append(contentsOf: enabled)
                    break
                }
            } else {
                let enabled = selectTransitionsForNode(node, event: event, snapshot: snapshot)
                if !enabled.isEmpty {
                    transitions.append(contentsOf: enabled)
                    break
                }
            }
        }
    }

    return dedupeTransitions(transitions)
}

func selectTransitions<Context: Sendable>(
    event: any Eventable,
    snapshot: MachineSnapshot<Context>
) -> [ResolvedTransition<Context>] {
    let exactAndPartial = selectTransitionsFromAtomicStates(
        event: event,
        snapshot: snapshot,
        wildcardFallback: false
    )
    if !exactAndPartial.isEmpty {
        return exactAndPartial
    }

    return selectTransitionsFromAtomicStates(
        event: event,
        snapshot: snapshot,
        wildcardFallback: true
    )
}

/// The direct child of a parallel parent containing `source`, or `source` itself.
func transitionRegionRoot<Context: Sendable>(for source: StateNode<Context>) -> StateNode<Context> {
    var current = source
    while let parent = current.parent {
        if parent.type == .parallel {
            return current
        }
        current = parent
    }
    return source
}

func isWithinRegion<Context: Sendable>(
    _ node: StateNode<Context>,
    region: StateNode<Context>
) -> Bool {
    node === region || isDescendant(node, of: region)
}

func computeTransitionExitNodes<Context: Sendable>(
    activeNodes: StateNodeSet<Context>,
    effectiveTargets: [StateNode<Context>],
    reenter: Bool,
    region: StateNode<Context>? = nil
) -> StateNodeSet<Context> {
    var exitNodes = StateNodeSet<Context>()

    for node in activeNodes {
        if let region, !isWithinRegion(node, region: region) {
            continue
        }

        let remainsInSubtree = effectiveTargets.contains { target in
            node === target || isDescendant(node, of: target)
        }
        if remainsInSubtree { continue }

        let targetUnderNode = effectiveTargets.contains { isDescendant($0, of: node) }
        if !targetUnderNode || reenter {
            exitNodes.insert(node)
        }
    }

    return exitNodes
}

func selectEventlessTransitions<Context: Sendable>(
    snapshot: MachineSnapshot<Context>,
    event: any Eventable
) -> [ResolvedTransition<Context>] {
    let atomicStates = snapshot._nodes.filter { $0.isAtomic() }
    var selected: [ResolvedTransition<Context>] = []
    var visited = Set<String>()

    for stateNode in atomicStates {
        let candidates = [stateNode] + getProperAncestors(stateNode, to: nil)
        search: for node in candidates {
            if visited.contains(node.id) {
                continue
            }
            visited.insert(node.id)

            for transition in node.always {
                let args = ActionArgs(context: snapshot.context, event: event)
                if evaluateGuard(
                    transition.config.guardRef,
                    args: args,
                    implementations: snapshot.machine.implementations,
                    stateValue: snapshot.value
                ) {
                    selected.append(transition)
                    break search
                }
            }
        }
    }

    return selected
}

/// Maximum microsteps per macrostep before treating the chart as unstable.
public let defaultMaxMacrostepIterations = 100

struct MacrostepMicrostep<Context: Sendable>: Sendable {
    let snapshot: MachineSnapshot<Context>
    let event: InspectionEventDescription
    let transitions: [ResolvedTransition<Context>]
}

func macrostep<Context: Sendable>(
    snapshot: MachineSnapshot<Context>,
    event: any Eventable,
    isInitial: Bool = false,
    pendingActions: [ExecutableAction<Context>] = [],
    maxIterations: Int = defaultMaxMacrostepIterations
) -> (
    snapshot: MachineSnapshot<Context>,
    actions: [ExecutableAction<Context>],
    microsteps: [MacrostepMicrostep<Context>]
) {
    var current = snapshot
    var allActions: [ExecutableAction<Context>] = []
    var recordedMicrosteps: [MacrostepMicrostep<Context>] = []
    var internalQueue: [any Eventable] = []
    var completedParallelNodes = Set<String>()
    var delayedRaises: [DelayedRaise] = []
    var nextEvent = event
    var shouldSelectEventless = true
    var iteration = 0

    func recordMicrostep(
        _ next: MachineSnapshot<Context>,
        event: any Eventable,
        transitions: [ResolvedTransition<Context>]
    ) {
        guard !transitions.isEmpty else { return }
        recordedMicrosteps.append(
            MacrostepMicrostep(
                snapshot: next,
                event: .describe(event),
                transitions: transitions
            )
        )
    }

    if isInitial, !pendingActions.isEmpty {
        let resolved = resolveRaiseActionsOnly(
            pendingActions,
            context: current.context,
            event: nextEvent,
            implementations: current.machine.implementations,
            internalQueue: &internalQueue,
            delayedRaises: &delayedRaises
        )
        allActions.append(contentsOf: resolved)
    } else if !isInitial {
        let transitions = selectTransitions(event: nextEvent, snapshot: current)
        let (next, actions) = microstep(
            transitions: transitions,
            snapshot: current,
            event: nextEvent,
            internalQueue: &internalQueue,
            delayedRaises: &delayedRaises,
            completedParallelNodes: &completedParallelNodes
        )
        current = next
        allActions.append(contentsOf: actions)
        recordMicrostep(next, event: nextEvent, transitions: transitions)
    }

    while current.status == .active {
        iteration += 1
        if iteration > maxIterations {
            fatalError(
                "Infinite loop detected: more than \(maxIterations) microsteps " +
                    "without reaching a stable state."
            )
        }

        var enabledTransitions = shouldSelectEventless
            ? selectEventlessTransitions(snapshot: current, event: nextEvent)
            : []

        let previousValue = enabledTransitions.isEmpty ? nil : current.value

        if enabledTransitions.isEmpty {
            if internalQueue.isEmpty {
                break
            }
            nextEvent = internalQueue.removeFirst()
            enabledTransitions = selectTransitions(event: nextEvent, snapshot: current)
        }

        let (next, actions) = microstep(
            transitions: enabledTransitions,
            snapshot: current,
            event: nextEvent,
            internalQueue: &internalQueue,
            delayedRaises: &delayedRaises,
            completedParallelNodes: &completedParallelNodes
        )
        current = next
        allActions.append(contentsOf: actions)
        recordMicrostep(next, event: nextEvent, transitions: enabledTransitions)

        if let previousValue {
            shouldSelectEventless = next.value != previousValue
        } else {
            shouldSelectEventless = true
        }
    }

    _ = delayedRaises
    return (current, allActions, recordedMicrosteps)
}

// MARK: - Microstep / Macrostep

typealias MicrostepResult<Context: Sendable> = (MachineSnapshot<Context>, [ExecutableAction<Context>])

func microstep<Context: Sendable>(
    transitions: [ResolvedTransition<Context>],
    snapshot: MachineSnapshot<Context>,
    event: any Eventable,
    internalQueue: inout [any Eventable],
    delayedRaises: inout [DelayedRaise],
    completedParallelNodes: inout Set<String>
) -> MicrostepResult<Context> {
    guard !transitions.isEmpty else {
        return (snapshot, [])
    }

    var actions: [ExecutableAction<Context>] = []
    for transition in transitions {
        if let transitionActions = transition.config.actions {
            actions.append(contentsOf: transitionActions.map { ExecutableAction(ref: $0) })
        }
    }

    let initialNodes = StateNodeSet(snapshot._nodes)
    var mutStateNodes = initialNodes
    var exitNodes = StateNodeSet<Context>()
    var historyValue = HistoryValue(copying: snapshot.historyValue)
    var changedState = false

    for transition in transitions {
        guard let rawTargets = transition.target, !rawTargets.isEmpty else {
            continue
        }

        let effectiveTargets = getEffectiveTargetStates(rawTargets, historyValue: historyValue)
        guard !effectiveTargets.isEmpty else { continue }

        changedState = true
        let region = transitionRegionRoot(for: transition.source)
        let transitionExits = computeTransitionExitNodes(
            activeNodes: mutStateNodes,
            effectiveTargets: effectiveTargets,
            reenter: transition.reenter,
            region: region
        )

        recordHistoryOnExit(
            exitingNodes: transitionExits,
            activeNodes: mutStateNodes,
            historyValue: &historyValue
        )

        for node in transitionExits {
            mutStateNodes.remove(node)
            for ancestor in getProperAncestors(node, to: region) {
                mutStateNodes.remove(ancestor)
            }
        }
        for node in transitionExits {
            exitNodes.insert(node)
        }

        for target in effectiveTargets {
            mutStateNodes.insert(target)
            for ancestor in getProperAncestors(target, to: nil) {
                mutStateNodes.insert(ancestor)
            }
        }
    }

    let newStateNodes: StateNodeSet<Context>
    let entryNodes: StateNodeSet<Context>
    if changedState {
        newStateNodes = getAllStateNodes(mutStateNodes)
        var entered = StateNodeSet<Context>()
        for node in newStateNodes where !initialNodes.contains(node) {
            entered.insert(node)
        }
        entryNodes = entered
    } else {
        newStateNodes = initialNodes
        entryNodes = StateNodeSet()
    }

    // Exit actions (in reverse order)
    let sortedExit = exitNodes.sorted { $0.order > $1.order }
    for node in sortedExit {
        actions.insert(contentsOf: node.exit.map { ExecutableAction(ref: $0) }, at: 0)
    }

    // Entry actions
    let sortedEntry = entryNodes.sorted { $0.order < $1.order }
    for node in sortedEntry {
        actions.append(contentsOf: node.entry.map { ExecutableAction(ref: $0) })
    }

    let newValue = getStateValue(root: snapshot.machine.root, nodes: newStateNodes)
    let newTags = getTags(from: newStateNodes)

    var newContext = snapshot.context
    var newStatus = snapshot.status
    var newOutput = snapshot.output
    var newError = snapshot.error
    actions = flattenActions(
        actions,
        context: newContext,
        event: event,
        stateValue: newValue,
        implementations: snapshot.machine.implementations
    )
    actions = resolveBuiltInActions(
        actions,
        context: &newContext,
        event: event,
        implementations: snapshot.machine.implementations,
        internalQueue: &internalQueue,
        delayedRaises: &delayedRaises
    )

    processEnteredFinalStates(
        entryNodes: entryNodes,
        activeNodes: newStateNodes,
        context: newContext,
        event: event,
        machine: snapshot.machine,
        completedParallelNodes: &completedParallelNodes,
        internalQueue: &internalQueue,
        status: &newStatus,
        output: &newOutput,
        error: &newError
    )

    let newSnapshot = MachineSnapshot(
        machine: snapshot.machine,
        value: newValue,
        context: newContext,
        nodes: newStateNodes.array(),
        tags: newTags,
        status: newStatus,
        historyValue: historyValue,
        output: newOutput,
        error: newError,
        children: snapshot.children
    )

    return (newSnapshot, actions)
}

func childStateNodes<Context: Sendable>(of node: StateNode<Context>) -> [StateNode<Context>] {
    node.states.values.filter { $0.type != .history }
}

func isInFinalState<Context: Sendable>(
    activeNodes: StateNodeSet<Context>,
    node: StateNode<Context>
) -> Bool {
    switch node.type {
    case .compound:
        return childStateNodes(of: node).contains { child in
            child.type == .final && activeNodes.contains(child)
        }
    case .parallel:
        return childStateNodes(of: node).allSatisfy { isInFinalState(activeNodes: activeNodes, node: $0) }
    case .final:
        return true
    default:
        return false
    }
}

func resolveMachineOutput<Context: Sendable>(
    machine: StateMachine<Context>,
    context: Context,
    event: any Eventable,
    rootCompletionNode: StateNode<Context>
) -> SendableValue? {
    let completionOutput: SendableValue?
    if rootCompletionNode.output != nil, rootCompletionNode.parent != nil {
        completionOutput = rootCompletionNode.output?(ActionArgs(context: context, event: event))
    } else {
        completionOutput = nil
    }
    let doneStateEvent = DoneStateEvent(stateId: rootCompletionNode.id, output: completionOutput)

    if let rootOutput = machine.root.output {
        return rootOutput(ActionArgs(context: context, event: doneStateEvent))
    }
    if rootCompletionNode.output != nil {
        return rootCompletionNode.output?(ActionArgs(context: context, event: event))
    }
    return nil
}

func processEnteredFinalStates<Context: Sendable>(
    entryNodes: StateNodeSet<Context>,
    activeNodes: StateNodeSet<Context>,
    context: Context,
    event: any Eventable,
    machine: StateMachine<Context>,
    completedParallelNodes: inout Set<String>,
    internalQueue: inout [any Eventable],
    status: inout SnapshotStatus,
    output: inout SendableValue?,
    error: inout SendableValue?
) {
    let enteredFinals = entryNodes
        .filter { $0.type == .final }
        .sorted { $0.order < $1.order }

    for finalNode in enteredFinals {
        if finalNode.tags.contains("terminal-error") {
            status = .error
            output = nil
            if let errorEvent = event as? ErrorActorEvent {
                error = SendableValue(errorEvent.error)
            }
            continue
        }

        let parent = finalNode.parent
        var ancestorMarker = parent?.type == .parallel ? parent : parent?.parent
        var rootCompletionNode: StateNode<Context> = ancestorMarker ?? finalNode

        if parent?.type == .compound {
            let finalOutput = finalNode.output?(ActionArgs(context: context, event: event))
            internalQueue.append(DoneStateEvent(stateId: parent!.id, output: finalOutput))
        }

        while let marker = ancestorMarker,
              marker.type == .parallel,
              !completedParallelNodes.contains(marker.id),
              isInFinalState(activeNodes: activeNodes, node: marker) {
            completedParallelNodes.insert(marker.id)
            internalQueue.append(DoneStateEvent(stateId: marker.id))
            rootCompletionNode = marker
            ancestorMarker = marker.parent
        }

        guard ancestorMarker == nil else { continue }

        status = .done
        output = resolveMachineOutput(
            machine: machine,
            context: context,
            event: event,
            rootCompletionNode: rootCompletionNode
        )
        error = nil
    }
}

func initialMicrostep<Context: Sendable>(
    machine: StateMachine<Context>,
    context: Context
) -> MicrostepResult<Context> {
    let historyValue = HistoryValue<Context>()
    let nodes: StateNodeSet<Context>

    if machine.root.type == .parallel {
        nodes = resolveInitialStateNodes(machine.root, historyValue: historyValue)
    } else if let initialKey = machine.config.initial ?? machine.states.keys.first,
              let initialNode = machine.states[initialKey] {
        nodes = resolveInitialStateNodes(initialNode, historyValue: historyValue)
    } else {
        fatalError("No initial state for machine \"\(machine.id)\"")
    }

    var actions: [ExecutableAction<Context>] = []
    let sortedEntry = nodes.sorted { $0.order < $1.order }
    for node in sortedEntry {
        actions.append(contentsOf: node.entry.map { ExecutableAction(ref: $0) })
    }

    var context = context
    let initEvent: any Eventable = SystemEvent.`init`
    for action in actions {
        let args = ActionArgs(context: context, event: initEvent)
        executeAssignOnly(action, context: &context, args: args, implementations: machine.implementations)
    }

    let value = getStateValue(root: machine.root, nodes: nodes)
    let tags = getTags(from: nodes)

    var status: SnapshotStatus = .active
    var output: SendableValue?
    var error: SendableValue?
    var completedParallelNodes = Set<String>()
    var internalQueue: [any Eventable] = []
    processEnteredFinalStates(
        entryNodes: nodes,
        activeNodes: nodes,
        context: context,
        event: initEvent,
        machine: machine,
        completedParallelNodes: &completedParallelNodes,
        internalQueue: &internalQueue,
        status: &status,
        output: &output,
        error: &error
    )

    let snapshot = MachineSnapshot(
        machine: machine,
        value: value,
        context: context,
        nodes: nodes.array(),
        tags: tags,
        status: status,
        historyValue: historyValue,
        output: output,
        error: error
    )

    return (snapshot, actions)
}

func isDescendant<Context: Sendable>(_ node: StateNode<Context>, of ancestor: StateNode<Context>) -> Bool {
    var current = node.parent
    while let p = current {
        if p === ancestor { return true }
        current = p.parent
    }
    return false
}
