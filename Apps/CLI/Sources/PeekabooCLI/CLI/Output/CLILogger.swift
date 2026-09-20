import Commander
import Foundation

/// Log level enumeration for structured logging
public enum LogLevel: Int, Comparable, Sendable {
    case trace = 0 // Most verbose
    case verbose = 1
    case debug = 2
    case info = 3
    case warning = 4
    case error = 5
    case critical = 6 // Most severe

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var name: String {
        switch self {
        case .trace: "TRACE"
        case .verbose: "VERBOSE"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        case .critical: "CRITICAL"
        }
    }
}

/// Thread-safe logging utility for Peekaboo.
///
/// Provides logging functionality that can switch between stderr output (for normal operation)
/// and buffered collection (for JSON output mode) to avoid interfering with structured output.
final class Logger: @unchecked Sendable {
    static let shared = Logger()
    private nonisolated(unsafe) var debugLogs: [String] = []
    private nonisolated(unsafe) var isJsonOutputMode = false
    private nonisolated(unsafe) var verboseMode = false
    private let defaultMinimumLogLevel: LogLevel
    private nonisolated(unsafe) var minimumLogLevel: LogLevel
    private let queue = DispatchQueue(label: "logger.queue", attributes: .concurrent)
    private let iso8601Formatter: ISO8601DateFormatter

    /// Performance tracking
    private nonisolated(unsafe) var performanceTimers: [String: Date] = [:]

    private init() {
        self.iso8601Formatter = ISO8601DateFormatter()
        self.iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Check environment for log level
        var configuredLevel: LogLevel = .warning
        if let envValue = ProcessInfo.processInfo.environment["PEEKABOO_LOG_LEVEL"],
           let envLevel = LogLevel.parse(raw: envValue) {
            configuredLevel = envLevel
        }
        self.defaultMinimumLogLevel = configuredLevel
        self.minimumLogLevel = configuredLevel
    }

    func setJsonOutputMode(_ enabled: Bool) {
        self.queue.sync(flags: .barrier) {
            self.isJsonOutputMode = enabled
            // Don't clear logs automatically - let tests manage this explicitly
        }
    }

    func setVerboseMode(_ enabled: Bool) {
        self.queue.sync(flags: .barrier) {
            self.verboseMode = enabled
            if enabled {
                self.minimumLogLevel = .verbose
            }
        }
    }

    func setMinimumLogLevel(_ level: LogLevel) {
        self.queue.sync(flags: .barrier) {
            self.minimumLogLevel = level
        }
    }

    func resetMinimumLogLevel() {
        self.queue.sync(flags: .barrier) {
            self.minimumLogLevel = self.defaultMinimumLogLevel
        }
    }

    var isVerbose: Bool {
        self.queue.sync {
            self.verboseMode
        }
    }

    /// Log a message at a specific level
    private func log(_ level: LogLevel, _ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
        guard level >= self.minimumLogLevel || (level == .verbose && self.verboseMode) else { return }

        // Convert metadata to a string representation outside the async closure
        let metadataString: String? = metadata.flatMap { dict in
            dict.isEmpty ? nil : dict.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        }

        let timestamp = self.iso8601Formatter.string(from: Date())
        let levelName = level.name
        var formattedMessage = "[\(timestamp)] \(levelName): \(message)"

        if let category {
            formattedMessage = "[\(timestamp)] \(levelName) [\(category)]: \(message)"
        }

        if let metadataString {
            formattedMessage += " {\(metadataString)}"
        }

        let shouldBuffer = self.isJsonOutputMode

        self.queue.async(flags: .barrier) { [formattedMessage] in
            if shouldBuffer {
                self.debugLogs.append(formattedMessage)
            } else {
                fputs("\(formattedMessage)\n", stderr)
            }
        }
    }

    func verbose(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
        self.log(.verbose, message, category: category, metadata: metadata)
    }

    func debug(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
        self.log(.debug, message, category: category, metadata: metadata)
    }

    func info(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
        self.log(.info, message, category: category, metadata: metadata)
    }

    func warn(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
        self.log(.warning, message, category: category, metadata: metadata)
    }

    func error(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
        self.log(.error, message, category: category, metadata: metadata)
    }

    func critical(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
        self.log(.critical, message, category: category, metadata: metadata)
    }

    // MARK: - Performance Tracking

    /// Start a performance timer
    func startTimer(_ name: String) {
        // Start a performance timer
        let timestamp = self.iso8601Formatter.string(from: Date())
        let verboseEnabled = self.verboseMode
        let shouldBuffer = self.isJsonOutputMode

        self.queue.async(flags: .barrier) {
            self.performanceTimers[name] = Date()
            if verboseEnabled {
                let message = "[\(timestamp)] VERBOSE [Performance]: Starting timer '\(name)'"
                if shouldBuffer {
                    self.debugLogs.append(message)
                } else {
                    fputs("\(message)\n", stderr)
                }
            }
        }
    }

    /// Stop a performance timer and log the duration
    func stopTimer(_ name: String, threshold: TimeInterval? = nil) {
        var startTime: Date?
        self.queue.sync(flags: .barrier) {
            startTime = self.performanceTimers[name]
            self.performanceTimers.removeValue(forKey: name)
        }

        guard let startTime else {
            self.log(.warning, "Timer '\(name)' was not started", category: "Performance")
            return
        }

        let duration = Date().timeIntervalSince(startTime)
        if self.verboseMode || (threshold != nil && duration > threshold!) {
            let durationMs = Int(duration * 1000)
            self.log(
                .verbose,
                "Timer '\(name)' completed",
                category: "Performance",
                metadata: ["duration_ms": durationMs]
            )
        }
    }

    // MARK: - Operation Tracking

    /// Log the start of an operation
    func operationStart(_ operation: String, metadata: [String: Any]? = nil) {
        // Log the start of an operation
        var meta = metadata ?? [:]
        meta["operation"] = operation
        self.verbose("Starting operation", category: "Operation", metadata: meta)
        self.startTimer(operation)
    }

    /// Log the completion of an operation
    func operationComplete(_ operation: String, success: Bool = true, metadata: [String: Any]? = nil) {
        // Log the completion of an operation
        var meta = metadata ?? [:]
        meta["operation"] = operation
        meta["success"] = success
        self.verbose("Operation completed", category: "Operation", metadata: meta)
        self.stopTimer(operation)
    }

    func getDebugLogs() -> [String] {
        self.queue.sync {
            self.debugLogs
        }
    }

    func clearDebugLogs() {
        self.queue.sync(flags: .barrier) {
            self.debugLogs.removeAll()
        }
    }

    /// For testing - ensures all pending operations are complete
    func flush() {
        // For testing - ensures all pending operations are complete
        self.queue.sync(flags: .barrier) {
            // This ensures all pending async operations are complete
        }
    }
}

public func logVerbose(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
    Logger.shared.verbose(message, category: category, metadata: metadata)
}

public func logDebug(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
    Logger.shared.debug(message, category: category, metadata: metadata)
}

public func logInfo(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
    Logger.shared.info(message, category: category, metadata: metadata)
}

public func logWarn(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
    Logger.shared.warn(message, category: category, metadata: metadata)
}

public func logError(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
    Logger.shared.error(message, category: category, metadata: metadata)
}

public func logCritical(_ message: String, category: String? = nil, metadata: [String: Any]? = nil) {
    Logger.shared.critical(message, category: category, metadata: metadata)
}

public enum CLIInstrumentation {
    public enum LoggerControl {
        public static func setJsonOutputMode(_ enabled: Bool) {
            Logger.shared.setJsonOutputMode(enabled)
        }

        public static func setVerboseMode(_ enabled: Bool) {
            Logger.shared.setVerboseMode(enabled)
        }

        public static func clearDebugLogs() {
            Logger.shared.clearDebugLogs()
        }

        public static func debugLogs() -> [String] {
            Logger.shared.getDebugLogs()
        }

        public static func flush() {
            Logger.shared.flush()
        }

        public static func setMinimumLogLevel(_ level: LogLevel) {
            Logger.shared.setMinimumLogLevel(level)
        }

        public static func resetMinimumLogLevel() {
            Logger.shared.resetMinimumLogLevel()
        }
    }
}

extension LogLevel {
    static func parse(raw: String) -> LogLevel? {
        switch raw.lowercased() {
        case "trace": .trace
        case "verbose": .verbose
        case "debug": .debug
        case "info": .info
        case "warning", "warn": .warning
        case "error": .error
        case "critical": .critical
        default: nil
        }
    }
}

extension LogLevel: ExpressibleFromArgument {
    public init?(argument: String) {
        guard let level = LogLevel.parse(raw: argument) else {
            return nil
        }
        self = level
    }
}
