import Foundation
import MacpoolVM
import Testing

/// Tests of MAC address parsing and lease lookup.
struct DHCPLeasesTests {
    /// A lease file with two guests in the format that `bootpd` writes.
    static let leaseFile = """
    {
    \tname=first
    \tip_address=192.168.64.2
    \thw_address=1,52:54:0:25:1e:21
    \tidentifier=1,52:54:0:25:1e:21
    \tlease=0x6ae268bb
    }
    {
    \tname=second
    \tip_address=192.168.64.7
    \thw_address=1,d6:c5:4f:ee:f7:9e
    \tidentifier=1,d6:c5:4f:ee:f7:9e
    \tlease=0x6ae26a00
    }

    """

    /// Parses addresses with one or two digits per octet and prints two digits.
    @Test func parsesShortenedOctets() throws {
        let address = try #require(MACAddress("52:54:0:25:1e:21"))
        #expect(address.octets == [0x52, 0x54, 0x00, 0x25, 0x1E, 0x21])
        #expect(address.description == "52:54:00:25:1e:21")
        #expect(MACAddress("52:54:00:25:1E:21") == address)
    }

    /// Rejects text that is not six hexadecimal octets.
    @Test(arguments: [
        "",
        "52:54:00:25:1e",
        "52:54:00:25:1e:21:00",
        "52:54:00:25:1e:zz",
        "52:54:000:25:1e:21",
        "52::00:25:1e:21",
    ])
    func rejectsMalformedAddresses(text: String) {
        #expect(MACAddress(text) == nil)
    }

    /// Finds each guest's lease by its MAC address in either form.
    @Test func findsLeaseByAddress() throws {
        let first = try #require(MACAddress("52:54:00:25:1e:21"))
        let second = try #require(MACAddress("d6:c5:4f:ee:f7:9e"))
        #expect(
            DHCPLeases.lease(for: first, inContents: Self.leaseFile)
                == DHCPLease(address: "192.168.64.2", expiry: "0x6ae268bb"),
        )
        #expect(
            DHCPLeases.lease(for: second, inContents: Self.leaseFile)
                == DHCPLease(address: "192.168.64.7", expiry: "0x6ae26a00"),
        )
    }

    /// Decodes the hexadecimal expiry and rejects other forms.
    @Test func decodesExpiry() {
        #expect(DHCPLease(address: "192.168.64.2", expiry: "0x6ae268bb").expiryDate
            == Date(timeIntervalSince1970: 0x6AE2_68BB))
        #expect(DHCPLease(address: "192.168.64.2", expiry: "6ae268bb").expiryDate == nil)
        #expect(DHCPLease(address: "192.168.64.2", expiry: "0xzz").expiryDate == nil)
    }

    /// Returns no lease for an unknown address or an incomplete block.
    @Test func ignoresUnknownAndIncompleteLeases() throws {
        let unknown = try #require(MACAddress("52:54:00:25:1e:22"))
        #expect(DHCPLeases.lease(for: unknown, inContents: Self.leaseFile) == nil)
        let incomplete = "{\n\tip_address=192.168.64.3\n\thw_address=1,52:54:0:25:1e:22\n}\n"
        #expect(DHCPLeases.lease(for: unknown, inContents: incomplete) == nil)
        let withoutType = "{\n\tip_address=192.168.64.3\n\thw_address=52:54:0:25:1e:22\n\tlease=0x1\n}\n"
        #expect(DHCPLeases.lease(for: unknown, inContents: withoutType) == nil)
    }

    /// Reads a lease file from disk and treats a missing file as having no leases.
    @Test func readsLeaseFile() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "leases")
        try Self.leaseFile.write(to: file, atomically: true, encoding: .utf8)
        let first = try #require(MACAddress("52:54:00:25:1e:21"))
        #expect(DHCPLeases.lease(for: first, in: file)?.address == "192.168.64.2")
        #expect(DHCPLeases.lease(for: first, in: directory.url.appending(path: "missing")) == nil)
    }
}
