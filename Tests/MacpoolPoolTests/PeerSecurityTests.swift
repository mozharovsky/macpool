@testable import MacpoolPool
import Network
import Testing

/// Tests of the TCP settings that ``PeerSecurity`` gives both sides of a connection.
struct PeerSecurityTests {
    /// Probes an idle peer so that a silent one drops after about a minute. The literal values
    /// pin that minute, so a change to the constants fails here.
    ///
    /// - Parameter isServer: Whether the parameters serve the host's listener or a client.
    @Test(arguments: [true, false])
    func probesIdlePeers(isServer: Bool) throws {
        let parameters = try PeerSecurity.parameters(identity: makeIdentity(), isServer: isServer) { _ in true }
        let tcp = try #require(parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
        #expect(tcp.enableKeepalive)
        #expect(tcp.keepaliveIdle == 30)
        #expect(tcp.keepaliveInterval == 10)
        #expect(tcp.keepaliveCount == 3)
    }
}
