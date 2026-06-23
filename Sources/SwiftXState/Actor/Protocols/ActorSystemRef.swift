/// Any actor that can be registered in an actor system.
public protocol ActorSystemRef: AnyObject, Sendable {
    var sessionId: String { get }
    var systemId: String? { get }
}
