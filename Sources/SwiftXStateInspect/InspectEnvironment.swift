import Foundation

/// Where the inspect client is running.
public enum InspectHostKind: String, Sendable, Equatable, Codable {
    case macApp
    case iOSDevice
    case iOSSimulator
    case watchApp
    case tvApp
    case linux
    case windows
    case unknown
}

/// Runtime context used to pick safe defaults per platform.
public struct InspectRuntimeContext: Sendable, Equatable {
    public var hostKind: InspectHostKind
    public var isDebugBuild: Bool
    public var isSimulator: Bool

    public init(
        hostKind: InspectHostKind = InspectRuntimeContext.detectedHostKind(),
        isDebugBuild: Bool = InspectRuntimeContext.detectedIsDebugBuild(),
        isSimulator: Bool = InspectRuntimeContext.detectedIsSimulator()
    ) {
        self.hostKind = hostKind
        self.isDebugBuild = isDebugBuild
        self.isSimulator = isSimulator
    }

    public static func detectedHostKind() -> InspectHostKind {
        #if os(macOS)
        return .macApp
        #elseif os(iOS)
        return detectedIsSimulator() ? .iOSSimulator : .iOSDevice
        #elseif os(watchOS)
        return .watchApp
        #elseif os(tvOS)
        return .tvApp
        #elseif os(Linux)
        return .linux
        #elseif os(Windows)
        return .windows
        #else
        return .unknown
        #endif
    }

    public static func detectedIsDebugBuild() -> Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public static func detectedIsSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}

/// Controls whether inspect I/O is permitted at runtime.
public struct InspectEnablement: Sendable, Equatable {
    public var requiresDebugBuild: Bool
    public var userOptIn: Bool

    public init(requiresDebugBuild: Bool = true, userOptIn: Bool = true) {
        self.requiresDebugBuild = requiresDebugBuild
        self.userOptIn = userOptIn
    }

    public func isEnabled(in context: InspectRuntimeContext) -> Bool {
        if requiresDebugBuild && !context.isDebugBuild { return false }
        return userOptIn
    }
}

/// Recommended policy, endpoint, and enablement per host environment.
public enum InspectDefaults {
    public static func recommendedPolicy(for context: InspectRuntimeContext) -> ConnectivityPolicy {
        switch context.hostKind {
        case .macApp, .iOSSimulator, .watchApp, .tvApp, .linux, .windows:
            return .localhostOnly(ports: .only([9234, 9235, 8080]))
        case .iOSDevice:
            // Device debugging often reaches a Mac-hosted inspector over LAN.
            return .privateNetwork(ports: .only([9234, 9235, 8080]))
        case .unknown:
            return .localhostOnly()
        }
    }

    public static func recommendedEndpoint(for context: InspectRuntimeContext) -> InspectEndpoint {
        switch context.hostKind {
        case .iOSDevice:
            // Consumers should override `host` with their Mac's LAN IP when needed.
            return InspectEndpoint(scheme: .ws, host: "127.0.0.1", port: 9234, path: "/inspect")
        case .linux, .windows:
            // Stately dev server commonly listens on 8080; inject a custom transport on these platforms.
            return InspectEndpoint(scheme: .ws, host: "127.0.0.1", port: 8080, path: "/")
        default:
            return InspectEndpoint()
        }
    }

    public static func recommendedEnablement(for context: InspectRuntimeContext) -> InspectEnablement {
        InspectEnablement(requiresDebugBuild: true, userOptIn: context.isDebugBuild)
    }
}

/// Full client configuration for attaching an inspect transport to an actor system.
public struct InspectClientConfiguration: Sendable {
    public var policy: ConnectivityPolicy
    public var endpoint: InspectEndpoint
    public var runtime: InspectRuntimeContext
    public var enablement: InspectEnablement
    public var wireFormat: InspectWireFormat
    public var machineDefinitions: [InspectMachineRegistration]
    public var eventFilter: (@Sendable (InspectionEvent) -> Bool)?

    public init(
        policy: ConnectivityPolicy? = nil,
        endpoint: InspectEndpoint? = nil,
        runtime: InspectRuntimeContext = InspectRuntimeContext(),
        enablement: InspectEnablement? = nil,
        wireFormat: InspectWireFormat = .stately,
        machineDefinitions: [InspectMachineRegistration] = [],
        eventFilter: (@Sendable (InspectionEvent) -> Bool)? = nil
    ) {
        self.runtime = runtime
        self.policy = policy ?? InspectDefaults.recommendedPolicy(for: runtime)
        self.endpoint = endpoint ?? InspectDefaults.recommendedEndpoint(for: runtime)
        self.enablement = enablement ?? InspectDefaults.recommendedEnablement(for: runtime)
        self.wireFormat = wireFormat
        self.machineDefinitions = machineDefinitions
        self.eventFilter = eventFilter
    }

    public var isEnabled: Bool {
        enablement.isEnabled(in: runtime)
    }
}