import Foundation
@testable import MacpoolPool
import Network
import Testing

/// Tests of the ranges of addresses that may reach the listener for paired Macs.
struct AddressRangeTests {
    /// Reads ranges and one address, and prints them in CIDR notation.
    @Test(arguments: zip(
        [
            "192.0.2.0/24", "192.0.2.30", "100.64.0.0/10", "0.0.0.0/0", "2001:DB8::/32", "fd7a:115c:a1e0::/48",
            "::1",
        ],
        [
            "192.0.2.0/24", "192.0.2.30/32", "100.64.0.0/10", "0.0.0.0/0", "2001:db8::/32", "fd7a:115c:a1e0::/48",
            "::1/128",
        ],
    ))
    func readsRanges(text: String, shown: String) throws {
        #expect(try #require(AddressRange(text)).description == shown)
    }

    /// Refuses bits after the prefix, long prefixes, host names, shortened and zoned addresses,
    /// and prefixes that are not plain numbers.
    @Test(arguments: [
        "192.0.2.20/24", "192.0.2.0/33", "2001:db8::/129", "lab.local/24", "127.1/32", "192.0.2.0/",
        "192.0.2.0/+8", "192.0.2.0/0024", "fe80::1%en0/64", "", "/24", "192.0.2.0/24/8",
    ])
    func refusesRanges(text: String) {
        #expect(AddressRange(text) == nil)
    }

    /// Holds the addresses that share the prefix, with an IPv4-mapped address as its IPv4 address.
    @Test func holdsAddressesWithThePrefix() throws {
        let tailnet = try #require(AddressRange("100.64.0.0/10"))
        #expect(tailnet.contains(host("100.127.255.255")))
        #expect(tailnet.contains(host("::ffff:100.64.0.1")))
        #expect(!tailnet.contains(host("100.128.0.1")))
        #expect(!tailnet.contains(host("2001:db8::1")))
        #expect(!tailnet.contains(.name("lab.local", nil)))

        let documentation = try #require(AddressRange("2001:db8::/32"))
        #expect(documentation.contains(host("2001:db8:1::5")))
        #expect(!documentation.contains(host("2001:db9::")))
        #expect(!documentation.contains(host("192.0.2.1")))
        #expect(try #require(AddressRange("0.0.0.0/0")).contains(host("203.0.113.9")))
        let single = try #require(AddressRange("192.0.2.30"))
        #expect(single.contains(host("192.0.2.30")))
        #expect(!single.contains(host("192.0.2.31")))
    }

    /// Lets every endpoint through without ranges, and only an IP address in a range with them.
    @Test func allowsEndpointsInTheRanges() throws {
        let ranges = try [#require(AddressRange("192.0.2.0/24"))]
        let inside = NWEndpoint.hostPort(host: host("192.0.2.7"), port: 7373)
        let outside = NWEndpoint.hostPort(host: host("198.51.100.7"), port: 7373)
        let service = NWEndpoint.service(name: "lab", type: "_macpool._tcp", domain: "local", interface: nil)
        #expect(PeerListener.allows(outside, from: []))
        #expect(PeerListener.allows(service, from: []))
        #expect(PeerListener.allows(inside, from: ranges))
        #expect(!PeerListener.allows(outside, from: ranges))
        #expect(!PeerListener.allows(service, from: ranges))
    }

    /// Reads a numeric address as a host.
    ///
    /// - Parameter text: An IPv4 or IPv6 address.
    /// - Returns: The host.
    private func host(_ text: String) -> NWEndpoint.Host {
        if let ipv4 = IPv4Address(text) {
            return .ipv4(ipv4)
        }
        if let ipv6 = IPv6Address(text) {
            return .ipv6(ipv6)
        }
        return .name(text, nil)
    }
}
