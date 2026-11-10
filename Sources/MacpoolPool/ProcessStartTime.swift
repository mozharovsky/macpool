import Darwin

/// Reads the time at which a running process started.
///
/// The kernel stores the time when the process was created and keeps it through `exec`. Later
/// changes of the system clock do not alter it, so two reads of one process agree to the
/// microsecond.
enum ProcessStartTime {
    /// Reads a process's start time.
    ///
    /// - Parameter processID: The process. It must belong to the calling user.
    /// - Returns: The start time in microseconds since 1970.
    /// - Throws: ``SupervisorMismatch/unreadableStartTime(errno:)`` when `proc_pidinfo` fails, as
    ///   it does for a process that exited or belongs to another user.
    static func read(processID: Int32) throws(SupervisorMismatch) -> UInt64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            throw .unreadableStartTime(errno: errno)
        }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}
