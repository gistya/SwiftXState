/// A globally-unique address for a hosted reactor: which Interactor it lives in, and its id there.
public struct ReactorAddress: Sendable, Equatable, Hashable, Codable {
    public let interactorID: String
    public let reactorID: String

    public init(interactorID: String, reactorID: String) {
        self.interactorID = interactorID
        self.reactorID = reactorID
    }

    /// A stable, collision-free node id for a unified graph: `interactor/reactor`.
    public var qualified: String { "\(interactorID)/\(reactorID)" }
}
