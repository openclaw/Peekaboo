//
//  TerminalColors.swift
//  PeekabooCLI
//

import Foundation

// MARK: - Terminal Color Codes

/// ANSI color codes for terminal output
public enum TerminalColor {
    public static let reset = "\u{001B}[0m"
    public static let bold = "\u{001B}[1m"
    public static let dim = "\u{001B}[2m"

    // Colors
    public static let blue = "\u{001B}[34m"
    public static let green = "\u{001B}[32m"
    public static let yellow = "\u{001B}[33m"
    public static let red = "\u{001B}[31m"
    public static let cyan = "\u{001B}[36m"
    public static let magenta = "\u{001B}[35m"
    public static let gray = "\u{001B}[90m"
    public static let italic = "\u{001B}[3m"
}

/// Update the terminal title using VibeTunnel or ANSI escape sequences
public func updateTerminalTitle(_ title: String) {
    // Try VibeTunnel first
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["vt", "title", title]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        try waitForTerminalTitleProcessExit(process)
        if process.terminationStatus == 0 {
            return
        }
    } catch {
        // VibeTunnel missing, failed, or wedged; fall through to ANSI
    }

    // Fallback to ANSI escape sequence
    print("\u{001B}]0;\(title)\u{0007}", terminator: "")
    fflush(stdout)
}

enum TerminalTitleProcessWaitError: Error {
    case timedOut
}

/// Wait for the VibeTunnel title process with a hard deadline.
///
/// Foundation's `waitUntilExit()` can block forever if a wedged `vt` is first on PATH.
nonisolated func waitForTerminalTitleProcessExit(
    _ process: Process,
    timeoutSeconds: TimeInterval = 2
) throws {
    do {
        try waitForProcessExit(process, timeoutSeconds: timeoutSeconds)
    } catch ProcessWaitError.timedOut {
        throw TerminalTitleProcessWaitError.timedOut
    }
}
