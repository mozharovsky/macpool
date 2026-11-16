import Foundation
import Network

/// The part of a peer's address that the listener for paired Macs counts handshake places by.
///
/// An IPv4 address counts alone, and an IPv4-mapped IPv6 address counts as its IPv4 address.
///
/// One party usually controls a whole IPv6 /64 network. An IPv6 address outside the listener's
/// /64 therefore counts by its /64. Every neighbor on the listener's link shares the listener's
/// /64, so an address inside it counts alone.
///
/// The listener takes no zone, so no client needs a link-local address. All link-local addresses
/// of one interface count as one source.
enum HandshakeSource: Hashable, Sendable {
    /// An IPv4 address.
    case ipv4(IPv4Address)

    /// An IPv6 address in the listener's /64 network.
    case ipv6(IPv6Address)

    /// The /64 network of an IPv6 address outside the listener's network, with the other 64 bits
    /// set to zero.
    case ipv6Network(IPv6Address)

    /// The link-local addresses of one interface.
    ///
    /// - Parameter interface: The interface's name, or an empty string when Network names none.
    case linkLocal(interface: String)

    /// The number of leading bytes that an IPv6 /64 network shares.
    private static let networkBytes = 8

    /// Finds the source of a connection.
    ///
    /// - Parameters:
    ///   - endpoint: The connection's remote endpoint.
    ///   - listener: The address that the listener binds to.
    /// - Returns: The source, or `nil` when the endpoint is not an IP address and a port.
    init?(_ endpoint: NWEndpoint, listener: NWEndpoint.Host) {
        guard case let .hostPort(host, _) = endpoint else {
            return nil
        }
        switch host {
        case let .ipv4(address):
            // The address may carry an interface, which would make one address two sources.
            guard let plain = IPv4Address(address.rawValue) else {
                return nil
            }
            self = .ipv4(plain)
        case let .ipv6(address):
            guard let source = Self.source(of: address, listener: listener) else {
                return nil
            }
            self = source
        default:
            return nil
        }
    }

    /// Finds the source of an IPv6 address.
    ///
    /// - Parameters:
    ///   - address: The peer's address.
    ///   - listener: The address that the listener binds to.
    /// - Returns: The source, or `nil` when Network rejects the address bytes.
    private static func source(of address: IPv6Address, listener: NWEndpoint.Host) -> HandshakeSource? {
        if address.isIPv4Mapped, let mapped = address.asIPv4 {
            return IPv4Address(mapped.rawValue).map(HandshakeSource.ipv4)
        }
        if address.isLinkLocal {
            return .linkLocal(interface: address.interface?.name ?? "")
        }
        let network = address.rawValue.prefix(networkBytes)
        if case let .ipv6(own) = listener, own.rawValue.prefix(networkBytes) == network {
            return IPv6Address(address.rawValue).map(HandshakeSource.ipv6)
        }
        return IPv6Address(network + Data(count: 16 - networkBytes)).map(HandshakeSource.ipv6Network)
    }
}
