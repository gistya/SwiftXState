/// A machine `Context` that can round-trip through ``JSONValue`` **without `Codable`**.
///
/// This is SwiftXState's persistence seam. The core module has no JSON *engine* and no reflection, so
/// it can't encode an arbitrary `Context` on its own — it asks the context to project itself instead.
/// That keeps persistence, replay, and inspection available under Embedded Swift, where `Codable`
/// (which needs existentials and type metadata) is unavailable.
///
/// **On Apple/Linux you don't implement this by hand.** Import `SwiftXStateCodable` and add the
/// conformance; both requirements are supplied for free by constrained extensions on `Encodable` /
/// `Decodable`:
///
/// ```swift
/// import SwiftXStateCodable
///
/// struct MyContext: Codable, ContextPersistable {}   // ← no body needed
/// ```
///
/// **On Embedded**, write the two members by hand — no reflection, no metadata, fully specializable:
///
/// ```swift
/// struct Counter: ContextPersistable {
///     var count: Int
///     func persistedProjection() throws -> JSONValue {
///         .object(["count": .number(Double(count))])
///     }
///     static func materialized(from json: JSONValue) throws -> Counter {
///         guard case let .object(fields) = json,
///               case let .number(count)? = fields["count"] else { throw PersistenceError.contextDecodingFailed }
///         return Counter(count: Int(count))
///     }
/// }
/// ```
public protocol ContextPersistable {
    /// Project this context into a ``JSONValue`` tree for persistence.
    func persistedProjection() throws -> JSONValue

    /// Rebuild a context from a previously projected ``JSONValue`` tree.
    static func materialized(from json: JSONValue) throws -> Self
}
