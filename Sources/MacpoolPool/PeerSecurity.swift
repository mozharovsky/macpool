import Foundation
import Network
import Security

/// The TLS settings of connections between Macs.
///
/// Both sides present a self-signed certificate for their Mac's key and check the key in the
/// other side's certificate. Only the first certificate that the peer sends counts. Its names,
/// dates, and issuer play no part. The system's trust evaluation never runs, so neither side
/// depends on the clock or on certificate authorities.
///
/// Connections use TLS 1.3 only. Session resumption and session tickets are off. Every
/// connection therefore runs a full handshake with both keys and accepts no early data.
///
/// Both sides turn on TCP keepalive. If the peer of an idle connection stops answering, TCP closes
/// the connection about a minute later.
enum PeerSecurity {
    /// The ALPN name of protocol version 1.
    static let protocolName = "macpool/1"

    /// The version number of ``protocolName``.
    static let protocolVersion = 1

    /// The protocol versions that this build speaks, keyed by their ALPN names.
    static let versions = [protocolName: protocolVersion]

    /// The seconds that a connection stays idle before TCP sends the first keepalive probe.
    static let keepaliveIdle = 30

    /// The seconds between keepalive probes.
    static let keepaliveInterval = 10

    /// The number of unanswered keepalive probes after which TCP drops the connection.
    static let keepaliveCount = 3

    /// Creates the parameters of a TCP connection with mutual TLS.
    ///
    /// The parameters call `admits` during every handshake. If a key leaves the host's list, that
    /// key opens no new connection.
    ///
    /// - Parameters:
    ///   - identity: This Mac's key and certificate. The connection presents them to the peer.
    ///   - protocols: The application protocols to offer or accept, in order of preference.
    ///   - isServer: Whether the parameters serve a listener. A listener requires a certificate
    ///     from every client.
    ///   - admits: Decides whether a peer's key may connect. It runs on a queue of its own and
    ///     must not block.
    /// - Returns: Parameters for a connection or a listener.
    /// - Throws: ``PoolError/unusableIdentity(path:reason:)`` when Security rejects the key.
    static func parameters(
        identity: MacIdentity,
        protocols: [String] = [protocolName],
        isServer: Bool,
        admits: @escaping @Sendable (KeyFingerprint) -> Bool,
    ) throws(PoolError) -> NWParameters {
        let secIdentity = try identity.secIdentity()
        guard let local = sec_identity_create(secIdentity) else {
            throw .unusableIdentity(
                path: identity.file.path(percentEncoded: false),
                reason: "Network does not accept its identity",
            )
        }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(options, local)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        for name in protocols {
            sec_protocol_options_add_tls_application_protocol(options, name)
        }
        if isServer {
            sec_protocol_options_set_peer_authentication_required(options, true)
        }
        sec_protocol_options_set_verify_block(options, { metadata, _, complete in
            complete(leafFingerprint(in: metadata).map(admits) ?? false)
        }, DispatchQueue(label: "macpool.peer.verify"))
        let tcp = NWProtocolTCP.Options()
        // A Mac that sleeps or leaves the network mid-request sends no FIN or RST. Without probes,
        // its connection would stay open until the daemon restarts.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = keepaliveIdle
        tcp.keepaliveInterval = keepaliveInterval
        tcp.keepaliveCount = keepaliveCount
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// Names the key in the first certificate that the peer sent.
    ///
    /// - Parameter metadata: The TLS metadata of a handshake or a ready connection.
    /// - Returns: The fingerprint, or `nil` when the peer sent no certificate or one without a
    ///   P-256 key.
    static func leafFingerprint(in metadata: sec_protocol_metadata_t) -> KeyFingerprint? {
        let leaf = LeafCertificate()
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            leaf.keep(sec_certificate_copy_ref(certificate).takeRetainedValue())
        }
        return leaf.first.flatMap(MacIdentity.keyDigest(of:)).map(KeyFingerprint.init(digest:))
    }

    /// Finds the protocol version that ALPN chose for a ready connection.
    ///
    /// - Parameter connection: A connection whose handshake finished.
    /// - Returns: The version, or `nil` when the connection carries no TLS metadata, ALPN chose no
    ///   protocol, or this build does not speak the chosen one.
    static func negotiatedVersion(of connection: NWConnection) -> Int? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              let name = sec_protocol_metadata_copy_negotiated_protocol(metadata.securityProtocolMetadata)
        else {
            return nil
        }
        defer { free(UnsafeMutablePointer(mutating: name)) }
        return versions[String(cString: name)]
    }

    /// Names the key that the peer of a ready connection proved.
    ///
    /// - Parameter connection: A connection whose handshake finished.
    /// - Returns: The fingerprint, or `nil` when the connection carries no TLS metadata or no
    ///   usable peer certificate.
    static func peerFingerprint(of connection: NWConnection) -> KeyFingerprint? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else {
            return nil
        }
        return leafFingerprint(in: metadata.securityProtocolMetadata)
    }
}

/// The first certificate of a chain that Security hands over one certificate at a time.
private final class LeafCertificate {
    /// The first certificate, once the chain delivered one.
    private(set) var first: SecCertificate?

    /// Keeps a certificate unless an earlier one arrived.
    ///
    /// - Parameter certificate: The next certificate of the chain.
    func keep(_ certificate: SecCertificate) {
        if first == nil {
            first = certificate
        }
    }
}
