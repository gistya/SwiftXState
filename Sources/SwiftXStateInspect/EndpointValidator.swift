import Foundation

/// Validates endpoints against a `ConnectivityPolicy` before any transport I/O.
public struct EndpointValidator: Sendable {
    public let policy: ConnectivityPolicy

    public init(policy: ConnectivityPolicy) {
        self.policy = policy
    }

    public func validate(_ endpoint: InspectEndpoint) throws -> InspectEndpoint {
        let host = endpoint.host.lowercased()
        let ports = portPolicy

        guard ports.allows(endpoint.port) else {
            throw InspectTransportError.policyViolation(
                host: host,
                reason: "Port \(endpoint.port) is not permitted"
            )
        }

        switch policy {
        case .localhostOnly:
            guard isLocalhost(host) else {
                throw InspectTransportError.policyViolation(
                    host: host,
                    reason: "Only loopback hosts are permitted"
                )
            }
        case .privateNetwork:
            guard isPrivateHost(host) else {
                throw InspectTransportError.policyViolation(
                    host: host,
                    reason: "Only private-network hosts are permitted"
                )
            }
        case let .allowlist(rules, _):
            guard matchesAllowlist(host: host, rules: rules) else {
                throw InspectTransportError.policyViolation(
                    host: host,
                    reason: "Host is not in the connectivity allowlist"
                )
            }
        }

        return endpoint
    }

    public func validate(url: URL) throws -> InspectEndpoint {
        guard let endpoint = InspectEndpoint(url: url) else {
            throw InspectTransportError.invalidEndpoint(url.absoluteString)
        }
        return try validate(endpoint)
    }

    private var portPolicy: PortPolicy {
        switch policy {
        case let .localhostOnly(ports), let .privateNetwork(ports), let .allowlist(_, ports):
            return ports
        }
    }

    private func isLocalhost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if let ipv4 = IPv4Address(host) {
            return ipv4.isLoopback
        }
        if host == "::1" { return true }
        if let ipv6 = IPv6Address(host) {
            return ipv6.isLoopback
        }
        return false
    }

    private func isPrivateHost(_ host: String) -> Bool {
        if isLocalhost(host) { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".local.") { return true }
        if let ipv4 = IPv4Address(host) {
            return ipv4.isLoopback || ipv4.isRFC1918 || ipv4.isLinkLocal
        }
        if let ipv6 = IPv6Address(host) {
            return ipv6.isLoopback || ipv6.isLinkLocal
        }
        return false
    }

    private func matchesAllowlist(host: String, rules: [HostRule]) -> Bool {
        for rule in rules {
            if rule.matches(host: host) { return true }
        }
        return false
    }
}

extension PortPolicy {
    func allows(_ port: Int) -> Bool {
        switch self {
        case .any:
            return true
        case let .only(ports):
            return ports.contains(port)
        }
    }
}

extension HostRule {
    func matches(host: String) -> Bool {
        let normalized = host.lowercased()
        switch self {
        case .localhost:
            return normalized == "localhost"
        case .loopback:
            if normalized == "localhost" { return true }
            if let ipv4 = IPv4Address(normalized) { return ipv4.isLoopback }
            if normalized == "::1" { return true }
            if let ipv6 = IPv6Address(normalized) { return ipv6.isLoopback }
            return false
        case .linkLocal:
            if let ipv4 = IPv4Address(normalized) { return ipv4.isLinkLocal }
            if let ipv6 = IPv6Address(normalized) { return ipv6.isLinkLocal }
            return false
        case .rfc1918ClassA:
            if let ipv4 = IPv4Address(normalized) { return ipv4.isInRange(10, 0, 0, 0, prefix: 8) }
            return false
        case .rfc1918ClassB:
            if let ipv4 = IPv4Address(normalized) { return ipv4.isInRange(172, 16, 0, 0, prefix: 12) }
            return false
        case .rfc1918ClassC:
            if let ipv4 = IPv4Address(normalized) { return ipv4.isInRange(192, 168, 0, 0, prefix: 16) }
            return false
        case .bonjourLocal:
            return normalized.hasSuffix(".local") || normalized.hasSuffix(".local.")
        case let .hostname(pattern):
            return normalized == pattern.lowercased()
        case let .ipv4CIDR(cidr):
            return IPv4Address(normalized)?.isInCIDR(cidr) == true
        case let .ipv6CIDR(cidr):
            return IPv6Address(normalized)?.isInCIDR(cidr) == true
        }
    }
}

struct IPv4Address: Sendable {
    let octets: (UInt8, UInt8, UInt8, UInt8)

    init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var values: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            values.append(value)
        }
        octets = (values[0], values[1], values[2], values[3])
    }

    var isLoopback: Bool {
        octets.0 == 127
    }

    var isLinkLocal: Bool {
        octets.0 == 169 && octets.1 == 254
    }

    var isRFC1918: Bool {
        isInRange(10, 0, 0, 0, prefix: 8)
            || isInRange(172, 16, 0, 0, prefix: 12)
            || isInRange(192, 168, 0, 0, prefix: 16)
    }

    func isInRange(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8, prefix: Int) -> Bool {
        let base = (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
        let address = (UInt32(octets.0) << 24) | (UInt32(octets.1) << 16)
            | (UInt32(octets.2) << 8) | UInt32(octets.3)
        let mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return (address & mask) == (base & mask)
    }

    func isInCIDR(_ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), let base = IPv4Address(String(parts[0])) else {
            return false
        }
        return isInRange(base.octets.0, base.octets.1, base.octets.2, base.octets.3, prefix: prefix)
    }
}

struct IPv6Address: Sendable {
    let words: [UInt16]

    init?(_ string: String) {
        let parsed: [UInt16]?
        if string == "::1" {
            var loopback = Array(repeating: UInt16(0), count: 8)
            loopback[7] = 1
            parsed = loopback
        } else if string.hasPrefix("fe80") || string.hasPrefix("FE80") {
            parsed = [0xFE80, 0, 0, 0, 0, 0, 0, 0]
        } else if string.contains(":") {
            parsed = nil
        } else {
            parsed = nil
        }
        guard let parsed else { return nil }
        words = parsed
    }

    var isLoopback: Bool {
        words.count == 8 && words[0...6].allSatisfy { $0 == 0 } && words[7] == 1
    }

    var isLinkLocal: Bool {
        words.first == 0xFE80
    }

    func isInCIDR(_: String) -> Bool { false }
}