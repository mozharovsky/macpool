import Foundation
import Network

/// A range of IP addresses in CIDR notation, such as `100.64.0.0/10` or `fd7a:115c:a1e0::/48`.
///
/// If ``PeerSettings/allowedSources`` holds ranges, the listener for paired Macs closes a
/// connection from an address outside them before its TLS handshake starts.
public struct AddressRange: Sendable, Hashable, CustomStringConvertible {
    /// The network's address bytes, 4 for IPv4 and 16 for IPv6. The bits after the prefix are
    /// zero.
    private let network: [UInt8]

    /// The network's address in the form that Network prints, such as `fd7a:115c:a1e0::`.
    private let address: String

    /// The number of leading bits that every address in the range shares with the network.
    public let prefixLength: Int

    /// Reads a range.
    ///
    /// An address without a prefix length stands for itself alone, as `/32` for IPv4 and `/128`
    /// for IPv6.
    ///
    /// - Parameter text: The range, such as `192.0.2.0/24`.
    /// - Returns: `nil` when the address is not a numeric IP address in its usual form, has a
    ///   zone, or has bits set after the prefix, or when the prefix length is not a number from 0
    ///   to 32 for IPv4 or to 128 for IPv6.
    public init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let addressText = String(parts[0])
        let bytes: [UInt8]
        let shown: String
        // Network also reads shortened IPv4 forms such as 127.1, which the range refuses.
        if let ipv4 = IPv4Address(addressText), addressText == "\(ipv4)" {
            bytes = [UInt8](ipv4.rawValue)
            shown = addressText
        } else if !addressText.contains("%"), let ipv6 = IPv6Address(addressText) {
            bytes = [UInt8](ipv6.rawValue)
            shown = "\(ipv6)"
        } else {
            return nil
        }
        let bits = bytes.count * 8
        let length: Int
        if parts.count == 2 {
            let digits = parts[1].utf8
            guard (1 ... 3).contains(digits.count), digits.allSatisfy({ (0x30 ... 0x39).contains($0) }),
                  let value = Int(parts[1]), value <= bits else {
                return nil
            }
            length = value
        } else {
            length = bits
        }
        // A range such as 192.0.2.20/24 is usually a typo for one address or for 192.0.2.0/24.
        guard Self.masked(bytes, to: length) == bytes else {
            return nil
        }
        network = bytes
        address = shown
        prefixLength = length
    }

    /// Reports whether the range holds an address.
    ///
    /// An IPv4-mapped IPv6 address, such as `::ffff:192.0.2.20`, counts as its IPv4 address.
    ///
    /// - Parameter host: The address of a connection's remote endpoint.
    /// - Returns: Whether the address is an IP address in the range.
    func contains(_ host: NWEndpoint.Host) -> Bool {
        let bytes: [UInt8]
        switch host {
        case let .ipv4(address):
            bytes = [UInt8](address.rawValue)
        case let .ipv6(address):
            if address.isIPv4Mapped, let mapped = address.asIPv4 {
                bytes = [UInt8](mapped.rawValue)
            } else {
                bytes = [UInt8](address.rawValue)
            }
        default:
            return false
        }
        return bytes.count == network.count && Self.masked(bytes, to: prefixLength) == network
    }

    /// The range in CIDR notation, with the prefix length.
    public var description: String {
        "\(address)/\(prefixLength)"
    }

    /// Clears the bits after a prefix.
    ///
    /// - Parameters:
    ///   - bytes: The address bytes.
    ///   - length: The number of leading bits to keep.
    /// - Returns: The bytes with every bit after the first `length` bits set to zero.
    private static func masked(_ bytes: [UInt8], to length: Int) -> [UInt8] {
        bytes.enumerated().map { index, byte in
            let kept = min(max(length - index * 8, 0), 8)
            return kept == 8 ? byte : byte & ~(0xFF >> kept)
        }
    }
}
