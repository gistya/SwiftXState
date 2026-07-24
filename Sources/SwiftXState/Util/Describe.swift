// MARK: - Reflection-free value description

/// A best-effort human-readable rendering of `value`, for **display only** — logs, inspector
/// payload strings, child-snapshot summaries.
///
/// Full Swift uses `String(describing:)`, which falls back to reflection for types that do not
/// conform to `CustomStringConvertible`. Embedded Swift has neither reflection nor the conditional
/// cast that would recover a `CustomStringConvertible` witness from an untyped value, so there the
/// result is always a placeholder.
///
/// Recovering a real description on Embedded would mean taking the value generically
/// (`describeValue<T: CustomStringConvertible>`), which the call sites cannot do — they hold
/// heterogeneous values behind `Any`.
///
/// - Important: Never use this where the result carries meaning — routing keys, identity, or
///   equality. A placeholder would collapse distinct values into one and fail silently. Identity is
///   handled explicitly instead: see ``StateEvent/eventType`` and ``BasicIdentifying/name``, both of
///   which become required declarations on Embedded rather than degrading.
func describeValue(_ value: Any) -> String {
    #if hasFeature(Embedded)
    return "<value>"
    #else
    return String(describing: value)
    #endif
}
