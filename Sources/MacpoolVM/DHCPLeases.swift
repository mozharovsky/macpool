public import Foundation

/// An Ethernet MAC address as six octets.
///
/// The host's lease file drops leading zeros from each octet, such as `52:54:0:25:1e:21`, while
/// the framework writes two digits per octet. Comparing parsed octets matches both forms.
public struct MACAddress: Sendable, Hashable, CustomStringConvertible {
    /// The six octets in transmission order.
    public let octets: [UInt8]

    /// Parses a colon-separated address with one or two hexadecimal digits per octet.
    ///
    /// - Parameter text: The address, such as `d6:c5:4f:ee:f7:9e`.
    /// - Returns: `nil` when the text does not hold exactly six hexadecimal octets.
    public init?(_ text: some StringProtocol) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else {
            return nil
        }
        var octets: [UInt8] = []
        for part in parts {
            guard (1 ... 2).contains(part.count), let octet = UInt8(part, radix: 16) else {
                return nil
            }
            octets.append(octet)
        }
        self.octets = octets
    }

    /// The address with two lowercase digits per octet.
    public var description: String {
        octets.map { octet in
            let digits = String(octet, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }
        .joined(separator: ":")
    }
}

/// One guest lease from the host's DHCP server.
public struct DHCPLease: Sendable, Hashable {
    /// The leased IPv4 address in dotted form.
    public let address: String

    /// The lease's expiry as the raw hexadecimal value from the lease file.
    ///
    /// A renewed lease receives a later expiry, which tells a new boot's lease from an old one.
    public let expiry: String

    /// The time the lease expires, or `nil` when the raw value is not a hexadecimal timestamp.
    ///
    /// `bootpd` writes the expiry as seconds since 1970 in hexadecimal with a `0x` prefix.
    public var expiryDate: Date? {
        guard expiry.hasPrefix("0x"), let seconds = UInt64(expiry.dropFirst(2), radix: 16) else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Creates a lease from its address and raw expiry.
    ///
    /// - Parameters:
    ///   - address: The leased IPv4 address.
    ///   - expiry: The raw hexadecimal expiry.
    public init(address: String, expiry: String) {
        self.address = address
        self.expiry = expiry
    }
}

/// Guest address lookup in the leases of the host's DHCP server.
///
/// NAT networking hands out guest addresses from the host's `bootpd`, which records every lease in
/// a world-readable file. The host therefore finds a guest's address from its MAC address
/// without any agent inside the guest.
public enum DHCPLeases {
    /// The lease file that `bootpd` maintains.
    public static let defaultFile = URL(filePath: "/var/db/dhcpd_leases")

    /// Finds the lease of a MAC address in a lease file.
    ///
    /// - Parameters:
    ///   - macAddress: The guest's MAC address.
    ///   - file: The lease file to read.
    /// - Returns: The lease, or `nil` when the file has no lease for the address or cannot be read.
    ///   The file is absent until the host's first NAT guest asks for an address.
    public static func lease(for macAddress: MACAddress, in file: URL = defaultFile) -> DHCPLease? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }
        return lease(for: macAddress, inContents: contents)
    }

    /// Finds the lease of a MAC address in the text of a lease file.
    ///
    /// Each lease is a brace-delimited block of `key=value` lines. The `hw_address` value starts
    /// with the hardware type, which is `1` for Ethernet, followed by a comma and the address.
    ///
    /// - Parameters:
    ///   - macAddress: The guest's MAC address.
    ///   - contents: The lease file's text.
    /// - Returns: The first complete lease for the address, or `nil` when there is none.
    public static func lease(for macAddress: MACAddress, inContents contents: String) -> DHCPLease? {
        var address: String?
        var hardware: MACAddress?
        var expiry: String?
        for line in contents.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                address = nil
                hardware = nil
                expiry = nil
            } else if line == "}" {
                if hardware == macAddress, let address, let expiry {
                    return DHCPLease(address: address, expiry: expiry)
                }
            } else if let value = line.value(after: "ip_address=") {
                address = value
            } else if let value = line.value(after: "hw_address=") {
                let parts = value.split(separator: ",", maxSplits: 1)
                hardware = parts.count == 2 ? MACAddress(parts[1]) : nil
            } else if let value = line.value(after: "lease=") {
                expiry = value
            }
        }
        return nil
    }
}

/// Line parsing for the lease file.
private extension String {
    /// Returns the rest of the line after a key prefix.
    ///
    /// - Parameter prefix: The key and its equals sign.
    /// - Returns: The value, or `nil` when the line has another key.
    func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
