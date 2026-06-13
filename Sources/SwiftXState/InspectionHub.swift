import Foundation

/// Merges the inspection streams of many ``Interactor``s into one unified picture.
///
/// Each Interactor is its own observability boundary (the bulkhead), so by default you'd watch
/// three Interactors as three streams. Attaching them to a hub gives you the single merged stream
/// the inspector/graph wants — events stay namespaced by their origin Interactor (so ids can't
/// collide across domains) and get a **global sequence number** assigned at this single merge
/// point. That global order is itself a Lamport clock at the hub: a consistent total order over
/// everything actually observed, in-process or (since it merges *streams*, not closures) across a
/// transport when an Interactor is remote.
///
/// Lock-based and `@unchecked Sendable`, matching the codebase's other registries (`ActorSystem`,
/// `InspectionCollector`) — the per-Interactor sinks fire on producer threads, so a global actor
/// would only add hops.
public final class InspectionHub: @unchecked Sendable {
    /// The unified output. Consume `events.stream()` to drive a merged graph / sequence view.
    public let events = EventBus()

    private let globalSeq = LamportClock()
    private let lock = NSLock()
    private var tokens: [String: Int] = [:]
    private var buses: [String: EventBus] = [:]

    public init() {}

    /// Begin merging an Interactor's events into the unified stream. Idempotent per Interactor id.
    @discardableResult
    public func attach(_ interactor: Interactor) -> Self {
        let interactorID = interactor.id
        let sourceBus = interactor.bus
        let out = events
        let seq = globalSeq

        lock.lock()
        if let existing = tokens[interactorID] {
            buses[interactorID]?.removeSink(existing)
        }
        let token = sourceBus.addSink { scoped in
            out.emit(scoped.withGlobalSeq(seq.tick()))
        }
        tokens[interactorID] = token
        buses[interactorID] = sourceBus
        lock.unlock()
        return self
    }

    /// Stop merging an Interactor's events.
    public func detach(_ interactorID: String) {
        lock.lock()
        if let token = tokens.removeValue(forKey: interactorID) {
            buses.removeValue(forKey: interactorID)?.removeSink(token)
        }
        lock.unlock()
    }

    /// A live, globally-ordered stream of every attached Interactor's events.
    public func stream() -> AsyncStream<ScopedInspectionEvent> { events.stream() }
}

// MARK: - Unified graph projection

/// A minimal model of the merged multi-Interactor picture: domain clusters of actors, plus the
/// cross-domain message edges between them. Built by folding the unified ``ScopedInspectionEvent``
/// stream — exactly the two-level (clusters + inter-domain edges) graph the inspector renders.
public struct UnifiedGraph: Sendable, Equatable {
    public struct Node: Sendable, Equatable, Hashable {
        public let address: ActorAddress
        public var machineID: String?
        public var stateValue: String?
        public var alive: Bool
    }

    public struct Edge: Sendable, Equatable, Hashable {
        public let from: ActorAddress
        public let to: ActorAddress
        public let event: String
        public var count: Int
    }

    public private(set) var nodes: [ActorAddress: Node] = [:]
    /// Attributed message edges (those with a known sender).
    public private(set) var edges: [Edge] = []
    /// Actor ids grouped by their Interactor (the clusters).
    public var clusters: [String: [ActorAddress]] {
        Dictionary(grouping: nodes.keys, by: \.interactorID).mapValues { $0.sorted { $0.actorID < $1.actorID } }
    }
    /// Just the edges that actually cross an Interactor boundary — the inter-domain wiring.
    public var crossDomainEdges: [Edge] {
        edges.filter { $0.from.interactorID != $0.to.interactorID }
    }

    public init() {}

    /// Fold one event into the graph.
    public mutating func apply(_ scoped: ScopedInspectionEvent) {
        switch scoped.payload {
        case let .inspection(event):
            let address = ActorAddress(interactorID: scoped.interactorID, actorID: event.actor.sessionId)
            var node = nodes[address] ?? Node(address: address, machineID: event.actor.machineId, stateValue: nil, alive: true)
            if let value = event.snapshot?.value { node.stateValue = value }
            if node.machineID == nil { node.machineID = event.actor.machineId }
            node.alive = event.snapshot?.status != .stopped
            nodes[address] = node

        case let .message(edge):
            // Only attributed sends (known sender) become graph edges; an unattributed external
            // send still flows through the live stream, it just isn't a node-to-node edge.
            guard let from = edge.from else { return }
            if let index = edges.firstIndex(where: { $0.from == from && $0.to == edge.to && $0.event == edge.event }) {
                edges[index].count += 1
            } else {
                edges.append(Edge(from: from, to: edge.to, event: edge.event, count: 1))
            }

        case let .lifecycle(lifecycle):
            var node = nodes[lifecycle.actor] ?? Node(address: lifecycle.actor, machineID: lifecycle.detail, stateValue: nil, alive: true)
            node.alive = lifecycle.kind != .stopped
            nodes[lifecycle.actor] = node
        }
    }
}
