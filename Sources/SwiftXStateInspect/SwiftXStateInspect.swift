// SwiftXStateInspect — pluggable inspect transports for devtools (v3).
//
// Hexagonal boundary: core emits `InspectionEvent`; this module moves bytes via
// injected `InspectTransport` implementations with `ConnectivityPolicy` guards.
//
// On Linux/Windows, bring your own networking with `ClosureInspectTransport` or
// any type conforming to `InspectTransport`. `SwiftXStateInspectURLSession` is
// optional and Apple-specific (URLSessionWebSocketTask).

@_exported import SwiftXState