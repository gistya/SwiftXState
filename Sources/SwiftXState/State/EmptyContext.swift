/// Context type for machines that don't need context.
public struct EmptyContext: Sendable, Equatable {
    public init() {}
}

// Codable is declared out-of-line and guarded — see CodableConformances.swift for the policy.
#if !hasFeature(Embedded)
extension EmptyContext: Codable {}
#endif
