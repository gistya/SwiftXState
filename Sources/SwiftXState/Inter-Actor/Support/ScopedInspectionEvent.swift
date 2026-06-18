import Foundation

/// An inspection event tagged with the Interactor it originated in, plus ordering metadata. This
/// is the envelope that crosses isolation boundaries and gets merged into one unified picture by
/// ``InspectionHub`` — the raw ``InspectionEvent`` is carried verbatim, so the XState-faithful
/// shape is untouched.
public struct ScopedInspectionEvent: Sendable, Identifiable {
    public enum Payload: Sendable {
        /// A normal runtime inspection event from a hosted reactor (`@xstate.*`).
        case inspection(InspectionEvent)
        /// A message routed across the inter-actor plane — the cross-domain edge of the graph.
        case message(MessageEdge)
        /// A supervision/lifecycle transition the Interactor itself performed.
        case lifecycle(Lifecycle)
    }

    public struct MessageEdge: Sendable, Equatable {
        public let from: ReactorAddress?
        public let to: ReactorAddress
        public let event: String
        public let correlation: UUID
    }

    public struct Lifecycle: Sendable, Equatable {
        public enum Kind: String, Sendable { case spawned, stopped, restarted, crashed }
        public let kind: Kind
        public let reactor: ReactorAddress
        public let detail: String?
    }

    public let id: UUID
    public let interactorID: String
    /// Per-Interactor causal clock.
    public let lamport: UInt64
    /// Total order assigned at the merge point by ``InspectionHub`` (nil until merged).
    public let globalSeq: UInt64?
    public let timestamp: TimeInterval
    public let payload: Payload

    public init(
        id: UUID = UUID(),
        interactorID: String,
        lamport: UInt64,
        globalSeq: UInt64? = nil,
        timestamp: TimeInterval,
        payload: Payload
    ) {
        self.id = id
        self.interactorID = interactorID
        self.lamport = lamport
        self.globalSeq = globalSeq
        self.timestamp = timestamp
        self.payload = payload
    }

    func withGlobalSeq(_ seq: UInt64) -> ScopedInspectionEvent {
        ScopedInspectionEvent(
            id: id, interactorID: interactorID, lamport: lamport,
            globalSeq: seq, timestamp: timestamp, payload: payload
        )
    }
}
