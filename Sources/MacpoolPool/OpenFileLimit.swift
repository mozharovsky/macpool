import Darwin

/// The process's limit of open files, which the daemon raises when it starts.
///
/// Every connection holds a file descriptor, and so do connections that wait for the daemon.
/// launchd starts a job with a soft limit of 256 by default. Without a higher limit, connections
/// from other Macs could use up the descriptors that the daemon needs for its state, its list of
/// paired clients, and the local socket.
enum OpenFileLimit {
    /// The soft limit that the daemon asks for.
    ///
    /// A paired Mac may hold 4 connections, so this limit leaves room for several hundred
    /// paired Macs.
    static let target: rlim_t = 4096

    /// The lowest limit at which the daemon listens for paired Macs.
    static let peerMinimum: rlim_t = 1024

    /// Raises the soft limit toward ``target`` and reads the limit back.
    ///
    /// The call never lowers the soft limit.
    ///
    /// - Returns: The number of files that the process may open, or `nil` when the limit cannot
    ///   be read.
    static func raise() -> rlim_t? {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            return nil
        }
        let perProcess = maximumPerProcess()
        let raised = raisedSoftLimit(soft: limit.rlim_cur, hard: limit.rlim_max, perProcess: perProcess)
        if raised > limit.rlim_cur {
            var wanted = rlimit(rlim_cur: raised, rlim_max: limit.rlim_max)
            // A refusal keeps the old limit, which the read below returns.
            _ = setrlimit(RLIMIT_NOFILE, &wanted)
        }
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            return nil
        }
        return min(limit.rlim_cur, perProcess)
    }

    /// Returns the soft limit that the daemon sets.
    ///
    /// - Parameters:
    ///   - soft: The current soft limit.
    ///   - hard: The hard limit, which only a privileged process may raise.
    ///   - perProcess: The kernel's limit for one process, `kern.maxfilesperproc`.
    /// - Returns: The least of `hard`, `perProcess`, and ``target``, or `soft` when it is higher.
    static func raisedSoftLimit(soft: rlim_t, hard: rlim_t, perProcess: rlim_t) -> rlim_t {
        max(soft, min(hard, perProcess, target))
    }

    /// Explains why the daemon does not listen for paired Macs.
    ///
    /// - Parameter limit: The limit that ``raise()`` returned.
    /// - Returns: The reason, or `nil` when the limit is at least ``peerMinimum``.
    static func peerRefusal(for limit: rlim_t?) -> String? {
        guard let limit else {
            return "the daemon cannot read its limit of open files"
        }
        guard limit < peerMinimum else {
            return nil
        }
        return "the daemon may open only \(limit) files, and the listener for paired Macs needs \(peerMinimum)"
    }

    /// Reads `kern.maxfilesperproc`.
    ///
    /// - Returns: The kernel's limit of open files for one process, or `rlim_t.max` when it
    ///   cannot be read.
    static func maximumPerProcess() -> rlim_t {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.maxfilesperproc", &value, &size, nil, 0) == 0, value > 0 else {
            return .max
        }
        return rlim_t(value)
    }
}
