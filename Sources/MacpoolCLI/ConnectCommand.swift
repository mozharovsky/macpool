import ArgumentParser
import Foundation
import MacpoolPool
import Synchronization
import System

/// Relays standard input and output to the SSH server of a lease's guest.
///
/// The command suits the `ProxyCommand` option of `ssh`, which passes the guest's SSH traffic
/// through the command's standard input and output. The bytes pass unchanged in both directions.
/// The command exits with status 0 once the stream ends normally.
///
/// Without `--pool` the command reaches the daemon on this Mac. A Unix socket carries no reset, so
/// a stream that the daemon breaks off, for example when the lease ends, also ends with status 0.
/// `ssh` still reports the break.
///
/// With `--pool` the command reaches a paired host over TLS, and the lease must belong to this
/// Mac. The command then fails when the stream breaks. TLS cannot end one direction alone, so the
/// end of standard input ends the whole stream.
struct ConnectCommand: AsyncParsableCommand {
    /// The subcommand's name and summary.
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Relays standard input and output to the SSH server of a lease's guest.",
    )

    /// The data directory of this Mac's daemon, which also holds this Mac's key and paired hosts.
    @OptionGroup var location: PoolOptions

    /// The paired host that holds the lease, if any.
    @OptionGroup var selection: HostSelection

    /// The lease whose guest to reach.
    @Argument(help: "The lease whose guest to reach.")
    var lease: String

    /// Opens the stream and relays bytes until it ends.
    ///
    /// - Throws: ``CommandError`` when the identifier is malformed, the daemon or host refuses the
    ///   stream, the stream breaks, or standard input or output fails.
    func run() async throws {
        try await perform()
    }

    /// Performs the subcommand with typed errors.
    ///
    /// - Throws: ``CommandError`` when the identifier is malformed, the daemon or host refuses the
    ///   stream, the stream breaks, or standard input or output fails.
    private func perform() async throws(CommandError) {
        let id = try LeaseID.parse(lease)
        let opened = try await selection.openStream(to: id, in: location.directory)
        // A write to a standard output that ssh closed then fails with EPIPE instead of ending the
        // process.
        signal(SIGPIPE, SIG_IGN)
        try await StandardRelay.run(opened.stream, input: .standardInput, output: .standardOutput)
    }
}

/// The option that selects a paired host instead of the daemon on this Mac.
struct HostSelection: ParsableArguments {
    /// The host's name or key, or `nil` for the daemon on this Mac.
    @Option(
        name: .customLong("pool"),
        help: "A paired host's name or short key from macpool pool list. The default is the daemon on this Mac.",
    )
    var host: String?

    /// Opens a stream to the SSH server of a lease's guest on the selected daemon.
    ///
    /// - Parameters:
    ///   - lease: The lease.
    ///   - directory: This Mac's data directory.
    /// - Returns: The stream and the lease.
    /// - Throws: ``CommandError/pool(_:)`` when the host is unknown, the connection fails, or the
    ///   daemon refuses the stream. A paired host's reason passes through
    ///   ``PeerText/escaped(_:)``.
    func openStream(to lease: LeaseID, in directory: PoolDirectory) async throws(CommandError) -> GuestStream {
        guard let host else {
            return try await pool { () async throws(PoolError) in
                try await PoolClient.openStream(to: lease, in: directory)
            }
        }
        do {
            let paired = try TrustedHost.named(host, in: directory)
            return try await PoolClient.openStream(to: lease, on: paired, directory: directory)
        } catch let .daemonRefused(message) {
            throw .pool(.daemonRefused(message: PeerText.escaped(message)))
        } catch let .unusableTrustList(path, reason) {
            throw .pool(.unusableTrustList(path: path, reason: PeerText.escaped(reason)))
        } catch {
            throw .pool(error)
        }
    }
}

/// The copying of bytes between a process's input and output and a byte stream.
///
/// Blocking reads and writes run on dispatch queues, so they stay off the threads of the
/// concurrency pool.
enum StandardRelay {
    /// Copies the input to the stream and the stream to the output until the stream ends.
    ///
    /// The end of the input ends the stream's sending direction. Over TLS that closes the stream,
    /// and the call then returns without an error. The call leaves both descriptors open.
    ///
    /// The copy reads a duplicate of `input` and closes it once the input ends or the stream
    /// fails. A read may still wait on the duplicate after the call returns.
    ///
    /// - Parameters:
    ///   - stream: The stream.
    ///   - input: The descriptor to read, such as standard input.
    ///   - output: The descriptor to write, such as standard output.
    /// - Throws: ``CommandError/pool(_:)`` when the stream breaks, or
    ///   ``CommandError/standardIO(operation:reason:)`` when the input or the output fails. A
    ///   failed output resets the stream.
    static func run(_ stream: ByteStream, input: FileDescriptor, output: FileDescriptor) async throws(CommandError) {
        // The caller may close input while a read still waits, and the system may give its number
        // to a new file. The duplicate keeps the read on the original file.
        let reading: FileDescriptor
        do {
            reading = try input.duplicate()
        } catch {
            throw .standardIO(operation: "reading standard input", reason: "\(error)")
        }
        let inputEnd = Mutex<InputEnd?>(nil)
        let copying = Task {
            await copyInput(from: reading, to: stream) { end in inputEnd.withLock { $0 = end } }
            try? reading.close()
        }
        while true {
            let data: Data?
            do throws(PoolError) {
                data = try await stream.receive()
            } catch {
                if inputEnd.withLock({ $0 }) == .ending {
                    // Over TLS the finish closes the stream before it returns, so the receive can
                    // fail first. The finish's own time limit bounds the wait.
                    await copying.value
                }
                switch inputEnd.withLock({ $0 }) {
                case .finished?:
                    return
                case let .failed(reason)?:
                    throw .standardIO(operation: "reading standard input", reason: reason)
                case .ending?, nil:
                    throw .pool(error)
                }
            }
            guard let data else {
                return
            }
            if let reason = await write(data, to: output) {
                stream.reset()
                throw .standardIO(operation: "writing standard output", reason: reason)
            }
        }
    }

    /// Copies an input to a stream until the input ends or fails, or the stream fails.
    ///
    /// The call records how the input ended before it ends or resets the stream. A receive that
    /// the stream's end wakes then finds the record.
    ///
    /// - Parameters:
    ///   - input: The descriptor to read.
    ///   - stream: The stream.
    ///   - record: Receives each stage of the input's end.
    private static func copyInput(
        from input: FileDescriptor,
        to stream: ByteStream,
        record: (InputEnd) -> Void,
    ) async {
        while true {
            switch await read(from: input) {
            case let .bytes(data):
                do throws(PoolError) {
                    try await stream.send(data)
                } catch {
                    return
                }
            case .end:
                record(.ending)
                do throws(PoolError) {
                    try await stream.finishSending()
                } catch {
                    return
                }
                record(.finished)
                return
            case let .failure(reason):
                record(.failed(reason))
                stream.reset()
                return
            }
        }
    }

    /// Reads the next bytes from a file descriptor.
    ///
    /// - Parameter descriptor: The descriptor.
    /// - Returns: Up to 64 KiB, the end of the input, or the system's description of a failure.
    private static func read(from descriptor: FileDescriptor) async -> InputChunk {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                do {
                    let count = try buffer.withUnsafeMutableBytes { try descriptor.read(into: $0) }
                    continuation.resume(returning: count == 0 ? .end : .bytes(Data(buffer.prefix(count))))
                } catch {
                    continuation.resume(returning: .failure("\(error)"))
                }
            }
        }
    }

    /// Writes bytes to a file descriptor.
    ///
    /// - Parameters:
    ///   - data: The bytes.
    ///   - descriptor: The descriptor.
    /// - Returns: The system's description of a failure, or `nil` once every byte was written.
    private static func write(_ data: Data, to descriptor: FileDescriptor) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    _ = try descriptor.writeAll(data)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: "\(error)")
                }
            }
        }
    }
}

/// One read from standard input.
private enum InputChunk: Sendable {
    /// Bytes that arrived.
    case bytes(Data)
    /// The input ended.
    case end
    /// The read failed.
    ///
    /// - Parameter reason: The system's description of the failure.
    case failure(String)
}

/// How the copying of standard input ended.
private enum InputEnd: Sendable, Equatable {
    /// The input ended, and the stream's sending direction is ending after its bytes.
    case ending
    /// The input ended, and the stream's sending direction ended after its bytes.
    case finished
    /// Reading the input failed, and the stream was reset.
    ///
    /// - Parameter reason: The system's description of the failure.
    case failed(String)
}
