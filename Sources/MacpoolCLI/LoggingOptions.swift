import ArgumentParser
import Logging

/// The diagnostic levels that the command line accepts.
///
/// The type mirrors `Logger.Level` so the option parses without a retroactive conformance on the
/// logging library's type.
enum LogLevel: String, CaseIterable, ExpressibleByArgument {
    /// Every message, including per-step tracing.
    case trace

    /// Configuration details and everything above them.
    case debug

    /// Lifecycle steps and everything above them.
    case info

    /// Framework events and everything above them.
    case notice

    /// Unexpected events and failures.
    case warning

    /// Failures only.
    case error

    /// Failures that end the process.
    case critical

    /// The equivalent level of the logging library.
    var level: Logger.Level {
        switch self {
        case .trace: .trace
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .warning: .warning
        case .error: .error
        case .critical: .critical
        }
    }
}

/// The option that selects how much diagnostic output reaches standard error.
///
/// Diagnostics go to standard error so that `measure` lines and the address on standard output
/// stay machine readable.
struct LoggingOptions: ParsableArguments {
    /// The lowest level that the command writes.
    @Option(name: .customLong("log-level"), help: "The lowest diagnostic level written to standard error.")
    var logLevel: LogLevel = .warning

    /// Creates a logger that writes to standard error at the selected level.
    ///
    /// The logger uses its own handler instead of the global logging system, so commands and tests
    /// can create loggers without a one-time bootstrap.
    ///
    /// - Parameter label: The label that identifies the logger's source.
    /// - Returns: A logger that drops messages below ``logLevel``.
    func makeLogger(label: String) -> Logger {
        var logger = Logger(label: label) { StreamLogHandler.standardError(label: $0) }
        logger.logLevel = logLevel.level
        return logger
    }
}
