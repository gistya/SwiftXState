/// A globally-unique address for a hosted actor: which Interactor it lives in, and its id there.
public struct ReactorAddress: Sendable, Equatable, Hashable, Codable {
    public let interactorID: String
    public let actorID: String

    public init(interactorID: String, actorID: String) {
        self.interactorID = interactorID
        self.actorID = actorID
    }

    /// A stable, collision-free node id for a unified graph: `interactor/actor`.
    public var qualified: String { "\(interactorID)/\(actorID)" }
}
