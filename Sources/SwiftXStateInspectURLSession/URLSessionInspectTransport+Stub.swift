#if !SWIFTXSTATE_URL_SESSION_WEBSOCKET
import Foundation
import SwiftXStateInspect

/// Indicates whether the Foundation `URLSession` WebSocket transport is available on this platform.
public enum URLSessionInspectPlatformSupport {
    public static let isAvailable = false
    public static let unavailableReason =
        "SwiftXStateInspectURLSession requires Apple platforms with URLSessionWebSocketTask. " +
        "On Linux and Windows, inject a custom InspectTransport (see ClosureInspectTransport)."
}

/// Stub transport that compiles on all platforms but fails fast if used without a custom implementation.
public final class URLSessionInspectTransport: InspectTransport, Sendable {
    public let policy: ConnectivityPolicy

    public init(policy: ConnectivityPolicy) {
        self.policy = policy
    }

    public func connect(to endpoint: InspectEndpoint) async throws -> any InspectSession {
        _ = endpoint
        throw InspectTransportError.platformUnavailable(URLSessionInspectPlatformSupport.unavailableReason)
    }
}

/// Convenience factory — returns a stub transport on non-Apple platforms.
public enum URLSessionInspect {
    public static func transport(
        policy: ConnectivityPolicy? = nil,
        runtime: InspectRuntimeContext = InspectRuntimeContext()
    ) -> URLSessionInspectTransport {
        _ = runtime
        return URLSessionInspectTransport(policy: policy ?? .localhostOnly())
    }

    public static func observer(
        policy: ConnectivityPolicy? = nil,
        endpoint: InspectEndpoint? = nil,
        runtime: InspectRuntimeContext = InspectRuntimeContext(),
        enablement: InspectEnablement? = nil,
        startImmediately: Bool = true
    ) -> @Sendable (InspectionEvent) -> Void {
        _ = endpoint
        _ = enablement
        _ = startImmediately
        let transport = transport(policy: policy, runtime: runtime)
        return createInspectObserver(
            transport: transport,
            configuration: InspectClientConfiguration(
                policy: policy,
                runtime: runtime,
                enablement: enablement
            ),
            startImmediately: false
        )
    }

    public static func statelyObserver<Context: Sendable>(
        machine: StateMachine<Context>,
        policy: ConnectivityPolicy? = nil,
        endpoint: InspectEndpoint? = nil,
        runtime: InspectRuntimeContext = InspectRuntimeContext(),
        enablement: InspectEnablement? = nil,
        startImmediately: Bool = true
    ) throws -> @Sendable (InspectionEvent) -> Void {
        _ = machine
        _ = endpoint
        _ = enablement
        _ = startImmediately
        return observer(policy: policy, runtime: runtime, startImmediately: false)
    }
}
#endif