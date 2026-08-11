import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation

private struct Point: Codable, Equatable {
    let x: Double
    let y: Double
}

private struct Rectangle: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct SystemSample: Codable {
    let timestamp: Double
    let frontmostPID: Int32?
    let frontmostBundleIdentifier: String?
    let frontmostWindowID: UInt32?
    let cursor: Point
    let clipboardChangeCount: Int
    let clipboardDigest: String
    let peekabooWindowIDs: [UInt32]
    let visibleScreenFramesTopLeft: [Rectangle]
}

private struct Violation: Codable, Hashable {
    let kind: String
    let expected: String
    let actual: String
}

private struct WatchHeartbeat: Codable {
    let sequence: UInt64
    let timestamp: Double
}

private struct AppIdentity: Codable {
    let bundleIdentifier: String
    let pid: Int32
    let isActive: Bool
}

private struct ProcessIdentity: Codable {
    let pid: Int32
    let startIdentity: UInt64
}

private enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case noMouseEvent

    var description: String {
        switch self {
        case let .invalidArguments(message): message
        case .noMouseEvent: "Unable to read the physical cursor location"
        }
    }
}

private func windowInfo() -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
}

private func frontmostWindowID(pid: Int32?, windows: [[String: Any]]) -> UInt32? {
    guard let pid else { return nil }

    return windows.first { window in
        guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              ownerPID == pid,
              let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer == 0
        else {
            return false
        }

        let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
        return alpha > 0
    }.flatMap { window in
        (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }
}

private func topWindowPID(windows: [[String: Any]]) -> Int32? {
    windows.first { window in
        let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
        let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
        return layer == 0 && alpha > 0
    }.flatMap { window in
        (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }
}

private func peekabooWindowIDs(windows: [[String: Any]]) -> [UInt32] {
    let pids = Set(NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
        guard let bundleIdentifier = app.bundleIdentifier?.lowercased(),
              bundleIdentifier.contains("peekaboo"),
              !bundleIdentifier.contains("playground")
        else {
            return nil
        }
        return app.processIdentifier
    })

    return windows.compactMap { window in
        guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              pids.contains(ownerPID),
              let number = window[kCGWindowNumber as String] as? NSNumber
        else {
            return nil
        }
        let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
        guard alpha > 0 else { return nil }
        return number.uint32Value
    }.sorted()
}

private func clipboardDigest(_ pasteboard: NSPasteboard) -> String {
    var hasher = SHA256()
    for item in pasteboard.pasteboardItems ?? [] {
        let types = item.types.sorted { $0.rawValue < $1.rawValue }
        for type in types {
            let typeData = Data(type.rawValue.utf8)
            hasher.update(data: withLengthPrefix(typeData))
            hasher.update(data: withLengthPrefix(item.data(forType: type) ?? Data()))
        }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func withLengthPrefix(_ data: Data) -> Data {
    var length = UInt64(data.count).bigEndian
    var result = Data(bytes: &length, count: MemoryLayout<UInt64>.size)
    result.append(data)
    return result
}

private func sample(includeClipboardDigest: Bool = true) throws -> SystemSample {
    guard let event = CGEvent(source: nil) else { throw ProbeError.noMouseEvent }
    let windows = windowInfo()
    let workspace = NSWorkspace.shared
    let windowOwnerPID = topWindowPID(windows: windows)
    let frontmost = windowOwnerPID.flatMap { pid in
        workspace.runningApplications.first { $0.processIdentifier == pid }
    } ?? workspace.frontmostApplication
    let frontmostPID = windowOwnerPID ?? frontmost?.processIdentifier
    let pasteboard = NSPasteboard.general
    let primaryDisplayHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
        ?? NSScreen.main)?.frame.height ?? 0
    let visibleScreenFramesTopLeft = NSScreen.screens.map { screen in
        let frame = screen.visibleFrame
        return Rectangle(
            x: frame.origin.x,
            y: primaryDisplayHeight - frame.maxY,
            width: frame.width,
            height: frame.height)
    }

    return SystemSample(
        timestamp: Date().timeIntervalSince1970,
        frontmostPID: frontmostPID,
        frontmostBundleIdentifier: frontmost?.bundleIdentifier,
        frontmostWindowID: frontmostWindowID(pid: frontmostPID, windows: windows),
        cursor: Point(x: event.location.x, y: event.location.y),
        clipboardChangeCount: pasteboard.changeCount,
        clipboardDigest: includeClipboardDigest ? clipboardDigest(pasteboard) : "",
        peekabooWindowIDs: peekabooWindowIDs(windows: windows),
        visibleScreenFramesTopLeft: visibleScreenFramesTopLeft)
}

private func processStartIdentity(pid: Int32) -> UInt64? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize else {
        return nil
    }
    let seconds = UInt64(info.pbi_start_tvsec)
    let microseconds = UInt64(info.pbi_start_tvusec)
    return seconds.multipliedReportingOverflow(by: 1_000_000).partialValue &+ microseconds
}

private func violations(
    baseline: SystemSample,
    current: SystemSample,
    allowClipboardMutation: Bool) -> Set<Violation>
{
    var result = Set<Violation>()

    if current.frontmostPID != baseline.frontmostPID {
        result.insert(Violation(
            kind: "frontmost_pid",
            expected: baseline.frontmostPID.map(String.init) ?? "null",
            actual: current.frontmostPID.map(String.init) ?? "null"))
    }
    if current.frontmostWindowID != baseline.frontmostWindowID {
        result.insert(Violation(
            kind: "frontmost_window",
            expected: baseline.frontmostWindowID.map(String.init) ?? "null",
            actual: current.frontmostWindowID.map(String.init) ?? "null"))
    }

    let cursorMoved = abs(current.cursor.x - baseline.cursor.x) > 0.5 ||
        abs(current.cursor.y - baseline.cursor.y) > 0.5
    if cursorMoved {
        result.insert(Violation(
            kind: "physical_cursor",
            expected: "\(baseline.cursor.x),\(baseline.cursor.y)",
            actual: "\(current.cursor.x),\(current.cursor.y)"))
    }

    if !allowClipboardMutation, current.clipboardChangeCount != baseline.clipboardChangeCount {
        result.insert(Violation(
            kind: "clipboard_change_count",
            expected: String(baseline.clipboardChangeCount),
            actual: String(current.clipboardChangeCount)))
    }

    let addedWindows = Set(current.peekabooWindowIDs).subtracting(baseline.peekabooWindowIDs)
    if !addedWindows.isEmpty {
        result.insert(Violation(
            kind: "peekaboo_overlay_window",
            expected: "none added",
            actual: addedWindows.sorted().map(String.init).joined(separator: ",")))
    }

    return result
}

private func writeJSON(_ value: some Encodable, to path: String?) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    if let path {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private func appendJSONLine(_ value: some Encodable, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value) + Data("\n".utf8)
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

private func argument(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private func runWatch(arguments: [String]) throws -> Never {
    guard let baselinePath = argument("--baseline", in: arguments),
          let outputPath = argument("--output", in: arguments),
          let readyPath = argument("--ready", in: arguments),
          let heartbeatPath = argument("--heartbeat", in: arguments)
    else {
        throw ProbeError.invalidArguments("watch requires --baseline, --output, --ready, and --heartbeat")
    }

    let intervalMilliseconds = Int(argument("--interval-ms", in: arguments) ?? "20") ?? 20
    let allowClipboardMutation = arguments.contains("--allow-clipboard-mutation")
    let baselineData = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
    let baseline = try JSONDecoder().decode(SystemSample.self, from: baselineData)
    FileManager.default.createFile(atPath: outputPath, contents: nil)

    var recorded = Set<Violation>()
    var firstSample = true
    var sequence: UInt64 = 0
    while true {
        let current = try sample(includeClipboardDigest: false)
        for violation in violations(
            baseline: baseline,
            current: current,
            allowClipboardMutation: allowClipboardMutation).subtracting(recorded)
        {
            try appendJSONLine(violation, to: outputPath)
            recorded.insert(violation)
        }
        sequence += 1
        try writeJSON(
            WatchHeartbeat(sequence: sequence, timestamp: current.timestamp),
            to: heartbeatPath)
        if firstSample {
            try Data("ready\n".utf8).write(to: URL(fileURLWithPath: readyPath), options: .atomic)
            firstSample = false
        }
        usleep(useconds_t(max(1, intervalMilliseconds) * 1000))
    }
}

private func runSelfTest() throws {
    let baseline = SystemSample(
        timestamp: 1,
        frontmostPID: 101,
        frontmostBundleIdentifier: "com.apple.calculator",
        frontmostWindowID: 201,
        cursor: Point(x: 50, y: 60),
        clipboardChangeCount: 3,
        clipboardDigest: "digest",
        peekabooWindowIDs: [301],
        visibleScreenFramesTopLeft: [Rectangle(x: 0, y: 0, width: 800, height: 600)])

    guard violations(baseline: baseline, current: baseline, allowClipboardMutation: false).isEmpty else {
        throw ProbeError.invalidArguments("equal samples must not produce violations")
    }

    let changed = SystemSample(
        timestamp: 2,
        frontmostPID: 102,
        frontmostBundleIdentifier: nil,
        frontmostWindowID: 202,
        cursor: Point(x: 51, y: 60),
        clipboardChangeCount: 4,
        clipboardDigest: "different",
        peekabooWindowIDs: [301, 302],
        visibleScreenFramesTopLeft: baseline.visibleScreenFramesTopLeft)
    let kinds = Set(violations(
        baseline: baseline,
        current: changed,
        allowClipboardMutation: false).map(\.kind))
    let expected: Set = [
        "frontmost_pid",
        "frontmost_window",
        "physical_cursor",
        "clipboard_change_count",
        "peekaboo_overlay_window",
    ]
    guard kinds == expected else {
        throw ProbeError.invalidArguments("self-test violation mismatch: \(kinds)")
    }
    let allowedKinds = Set(violations(
        baseline: baseline,
        current: changed,
        allowClipboardMutation: true).map(\.kind))
    guard !allowedKinds.contains("clipboard_change_count") else {
        throw ProbeError.invalidArguments("clipboard mutation allowance was ignored")
    }

    guard processStartIdentity(pid: getpid()) != nil else {
        throw ProbeError.invalidArguments("process generation lookup failed for the probe")
    }

    try writeJSON(SelfTestResult(success: true, tests: 4), to: nil)
}

private func findApp(arguments: [String]) throws {
    guard let bundleIdentifier = argument("--bundle-id", in: arguments) else {
        throw ProbeError.invalidArguments("find-app requires --bundle-id")
    }
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
    }) else {
        throw ProbeError.invalidArguments("controlled app is not running: \(bundleIdentifier)")
    }
    try writeJSON(
        AppIdentity(
            bundleIdentifier: bundleIdentifier,
            pid: app.processIdentifier,
            isActive: app.isActive),
        to: argument("--output", in: arguments))
}

private func writeProcessIdentity(arguments: [String]) throws {
    guard let value = argument("--pid", in: arguments),
          let pid = Int32(value),
          let startIdentity = processStartIdentity(pid: pid)
    else {
        throw ProbeError.invalidArguments("process-identity requires a live positive --pid")
    }
    try writeJSON(
        ProcessIdentity(pid: pid, startIdentity: startIdentity),
        to: argument("--output", in: arguments))
}

private struct SelfTestResult: Encodable {
    let success: Bool
    let tests: Int
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let mode = arguments.first else {
        throw ProbeError.invalidArguments("expected sample, watch, find-app, process-identity, or self-test")
    }
    switch mode {
    case "sample":
        try writeJSON(sample(), to: argument("--output", in: arguments))
    case "watch":
        try runWatch(arguments: arguments)
    case "find-app":
        try findApp(arguments: arguments)
    case "process-identity":
        try writeProcessIdentity(arguments: arguments)
    case "self-test":
        try runSelfTest()
    default:
        throw ProbeError.invalidArguments("unknown mode: \(mode)")
    }
} catch {
    FileHandle.standardError.write(Data("background-computer-use-probe: \(error)\n".utf8))
    exit(2)
}
