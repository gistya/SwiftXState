import Foundation

/// How local network access is scoped for inspect transports.
public enum ConnectivityPolicy: Sendable, Equatable {
    /// Loopback only (`127.0.0.1`, `::1`, `localhost`).
    case localhostOnly(ports: PortPolicy = .any)
    /// RFC1918, link-local, and loopback addresses.
    case privateNetwork(ports: PortPolicy = .any)
    /// Explicit host rules — escape hatch for Bonjour (`.local`) and custom subnets.
    case allowlist(rules: [HostRule], ports: PortPolicy = .any)
}

/// Port constraints applied alongside address policy.
public enum PortPolicy: Sendable, Equatable {
    case any
    case only(Set<Int>)
}

/// A host matching rule for `ConnectivityPolicy.allowlist`.
public enum HostRule: Sendable, Equatable {
    case localhost
    case loopback
    case linkLocal
    case rfc1918ClassA
    case rfc1918ClassB
    case rfc1918ClassC
    case bonjourLocal
    case hostname(String)
    case ipv4CIDR(String)
    case ipv6CIDR(String)
}

/// Supported inspect wire schemes. Only local/private targets are permitted.
public enum InspectScheme: String, Sendable, Equatable, Codable {
    case ws
    case wss
    case http
    case https
}

/// A network endpoint the inspect transport may connect to.
public struct InspectEndpoint: Sendable, Equatable, Codable {
    public var scheme: InspectScheme
    public var host: String
    public var port: Int
    public var path: String

    public init(
        scheme: InspectScheme = .ws,
        host: String = "127.0.0.1",
        port: Int = 9234,
        path: String = "/inspect"
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        components.port = port
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url
    }

    public init?(url: URL) {
        guard let schemeRaw = url.scheme,
              let scheme = InspectScheme(rawValue: schemeRaw),
              let host = url.host
        else { return nil }

        self.scheme = scheme
        self.host = host
        self.port = url.port ?? Self.defaultPort(for: scheme)
        self.path = url.path.isEmpty ? "/" : url.path
    }

    private static func defaultPort(for scheme: InspectScheme) -> Int {
        switch scheme {
        case .ws, .http: return 80
        case .wss, .https: return 443
        }
    }
}

/// Errors thrown when policy validation or transport operations fail.
public enum InspectTransportError: Error, Sendable, Equatable {
    case disabled
    case policyViolation(host: String, reason: String)
    case invalidEndpoint(String)
    case connectionFailed(String)
    case encodingFailed
    case notConnected
    case platformUnavailable(String)
}

extension ConnectivityPolicy {
    /// Default rules bundled with `allowlist` presets.
    public static var standardPrivateAllowlist: [HostRule] {
        [
            .localhost,
            .loopback,
            .linkLocal,
            .rfc1918ClassA,
            .rfc1918ClassB,
            .rfc1918ClassC,
            .bonjourLocal,
        ]
    }
}