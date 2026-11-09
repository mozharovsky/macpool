@testable import MacpoolVM
import Testing

/// Tests of host key parsing, fingerprints, and pinning lines.
struct HostKeyTests {
    /// An Ed25519 public key that `ssh-keygen` generated for these tests.
    static let first = "AAAAC3NzaC1lZDI1NTE5AAAAIC4OFXkBF8XtF6g+22oCPgkIWetqOctnrfRDbjmfJryJ"

    /// A second Ed25519 public key from `ssh-keygen`.
    static let second = "AAAAC3NzaC1lZDI1NTE5AAAAIDTFFqC0+AS9F1ctYHpDjk9T6wBzzu+UZuI5MnwVYqc6"

    /// An ECDSA public key from `ssh-keygen`, which macpool does not pin.
    static let ecdsa = """
    AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBA0kQGSmHImOBta41tHtXaToaYGKI0wbFyLawGNqN6VGlZU4GBPkX\
    GbAloxliQ3VscvRFueAnTY2jpnM25cNMK4=
    """

    /// Parses a public key line and computes the fingerprint that `ssh-keygen -l` prints.
    @Test func parsesPublicKeyLine() throws {
        let key = try #require(HostKey(publicKeyLine: "ssh-ed25519 \(Self.first) root@guest\n"))
        #expect(key.base64 == Self.first)
        #expect(key.fingerprint == "SHA256:7VOWxpWSiTj17QDvexyIIp/4kP6O7EsG90RKUtXCUBI")
        #expect(key.knownHostsLine(alias: "macpool-guest") == "macpool-guest ssh-ed25519 \(Self.first)")
    }

    /// Rejects lines of other key types, mislabeled blobs, and text that is not base64.
    @Test func rejectsOtherKeys() {
        #expect(HostKey(publicKeyLine: "ecdsa-sha2-nistp256 \(Self.ecdsa)") == nil)
        #expect(HostKey(publicKeyLine: "ssh-ed25519 \(Self.ecdsa)") == nil)
        #expect(HostKey(publicKeyLine: "ssh-ed25519 not-base64") == nil)
        #expect(HostKey(publicKeyLine: "ssh-ed25519") == nil)
        #expect(HostKey(publicKeyLine: "") == nil)
    }

    /// Collects Ed25519 keys under any host name and skips everything else.
    @Test func collectsPinnedKeys() {
        let text = """
        # A comment
        192.168.64.4 ssh-ed25519 \(Self.first)
        @cert-authority * ssh-ed25519 \(Self.second)
        192.168.64.4 ecdsa-sha2-nistp256 \(Self.ecdsa)
        macpool-guest ssh-ed25519 \(Self.first)
        macpool-guest ssh-ed25519 \(Self.second) comment

        """
        let keys = HostKey.pinnedKeys(inKnownHosts: text)
        #expect(keys.map(\.base64) == [Self.first, Self.second])
        #expect(HostKey.pinnedKeys(inKnownHosts: "").isEmpty)
    }

    /// Leaves out a key that any `@revoked` line names, before or after its pin.
    @Test func dropsRevokedKeys() {
        let text = """
        192.168.64.4 ssh-ed25519 \(Self.first)
        macpool-guest ssh-ed25519 \(Self.second)
        @revoked 192.168.64.4 ssh-ed25519 \(Self.first)
        """
        #expect(HostKey.pinnedKeys(inKnownHosts: text).map(\.base64) == [Self.second])
        let allRevoked = "@revoked * ssh-ed25519 \(Self.second)\nmacpool-guest ssh-ed25519 \(Self.second)\n"
        #expect(HostKey.pinnedKeys(inKnownHosts: allRevoked).isEmpty)
    }
}
