import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Security

@_silgen_name("csops")
private func calibrationCSOps(
    _ processIdentifier: pid_t,
    _ operation: UInt32,
    _ userAddress: UnsafeMutableRawPointer?,
    _ userSize: Int) -> Int32

private enum CalibrationError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}

private struct Bounds: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct TargetReceipt: Codable, Equatable {
    let pid: Int32
    let startIdentity: String
    let windowID: UInt32
    let bounds: Bounds

    private enum CodingKeys: String, CodingKey {
        case pid
        case startIdentity = "start_identity"
        case windowID = "window_id"
        case bounds
    }
}

private struct CodeIdentity: Codable, Equatable {
    let pid: Int32
    let startIdentity: String
    let executablePath: String
    let executableSHA256: String
    let teamID: String
    let codeSignatureHash: String
    let signingIdentifier: String
    let appleAnchored: Bool

    private enum CodingKeys: String, CodingKey {
        case pid
        case startIdentity = "start_identity"
        case executablePath = "executable_path"
        case executableSHA256 = "executable_sha256"
        case teamID = "team_id"
        case codeSignatureHash = "code_signature_hash"
        case signingIdentifier = "signing_identifier"
        case appleAnchored = "apple_anchored"
    }
}

private struct CapturedEvent: Codable {
    let type: String
    let sourcePID: Int32
    let sourceStartIdentityAtCallback: String
    let timestampNanoseconds: String

    private enum CodingKeys: String, CodingKey {
        case type
        case sourcePID = "source_pid"
        case sourceStartIdentityAtCallback = "source_start_identity_at_callback"
        case timestampNanoseconds = "timestamp_nanoseconds"
    }
}

private struct CalibrationReceipt: Codable {
    let version: Int
    let eventCount: Int
    let settleMilliseconds: Int
    let target: TargetReceipt
    let capturedEvent: CapturedEvent
    let before: CodeIdentity
    let after: CodeIdentity

    private enum CodingKeys: String, CodingKey {
        case version
        case eventCount = "event_count"
        case settleMilliseconds = "settle_milliseconds"
        case target
        case capturedEvent = "captured_event"
        case before
        case after
    }
}

private struct SelfTestReceipt: Codable {
    let success: Bool
    let tests: Int
}

private final class EventState {
    private let lock = NSLock()
    private var values: [CapturedEvent] = []

    func append(type: CGEventType, event: CGEvent) {
        let sourcePID = Int32(event.getIntegerValueField(.eventSourceUnixProcessID))
        let startIdentity = processStartIdentity(pid: sourcePID).map(String.init) ?? ""
        let receipt = CapturedEvent(
            type: eventTypeName(type),
            sourcePID: sourcePID,
            sourceStartIdentityAtCallback: startIdentity,
            timestampNanoseconds: String(event.timestamp))
        self.lock.lock()
        self.values.append(receipt)
        self.lock.unlock()
    }

    func snapshot() -> [CapturedEvent] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.values
    }
}

private struct Arguments {
    let targetPID: Int32
    let targetStartIdentity: String
    let targetWindowID: UInt32
    let timeoutSeconds: Int
    let settleMilliseconds: Int
    let outputPath: String
}

private let eligibleTypes: Set<CGEventType> = [
    .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged, .scrollWheel,
]

private func eventTypeName(_ type: CGEventType) -> String {
    switch type {
    case .leftMouseDown: "left_mouse_down"
    case .rightMouseDown: "right_mouse_down"
    case .otherMouseDown: "other_mouse_down"
    case .keyDown: "key_down"
    case .flagsChanged: "flags_changed"
    case .scrollWheel: "scroll_wheel"
    default: "ineligible_\(type.rawValue)"
    }
}

private func eventMask() -> CGEventMask {
    eligibleTypes.reduce(CGEventMask(0)) { result, type in
        result | (CGEventMask(1) << CGEventMask(type.rawValue))
    }
}

private let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard eligibleTypes.contains(type), let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    Unmanaged<EventState>.fromOpaque(userInfo).takeUnretainedValue().append(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

private func processStartIdentity(pid: Int32) -> UInt64? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize else { return nil }
    let seconds = UInt64(info.pbi_start_tvsec)
    let microseconds = UInt64(info.pbi_start_tvusec)
    let product = seconds.multipliedReportingOverflow(by: 1_000_000)
    guard !product.overflow else { return nil }
    let sum = product.partialValue.addingReportingOverflow(microseconds)
    return sum.overflow ? nil : sum.partialValue
}

private func canonicalPath(_ rawPath: String) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let result = rawPath.withCString { source in
        buffer.withUnsafeMutableBufferPointer { destination in
            realpath(source, destination.baseAddress)
        }
    }
    guard result != nil else { return nil }
    return String(cString: buffer)
}

private func executablePath(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return canonicalPath(String(cString: buffer))
}

private func hex(_ data: some Sequence<UInt8>) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func appleRequirement(teamID: String) -> SecRequirement? {
    guard teamID.utf8.count == 10,
          teamID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) })
    else { return nil }
    let source = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess else { return nil }
    return requirement
}

private func liveCodeSignatureHash(pid: Int32) -> Data? {
    var hash = [UInt8](repeating: 0, count: 20)
    let result = hash.withUnsafeMutableBytes { bytes in
        calibrationCSOps(pid, 5, bytes.baseAddress, bytes.count)
    }
    guard result == 0, hash.contains(where: { $0 != 0 }) else { return nil }
    return Data(hash)
}

private func codeIdentity(pid: Int32, expectedStartIdentity: String? = nil) throws -> CodeIdentity {
    guard let startBefore = processStartIdentity(pid: pid).map(String.init),
          expectedStartIdentity == nil || startBefore == expectedStartIdentity,
          let kernelPath = executablePath(pid: pid)
    else { throw CalibrationError.invalid("emitter process generation is not live") }
    let descriptor = open(kernelPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw CalibrationError.invalid("cannot open emitter executable") }
    defer { close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
        throw CalibrationError.invalid("emitter executable is not one regular file")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    guard lseek(descriptor, 0, SEEK_SET) == 0 else {
        throw CalibrationError.invalid("cannot seek emitter executable")
    }
    let bytes = try handle.readToEnd() ?? Data()
    let executableDigest = hex(SHA256.hash(data: bytes))

    let attributes: NSDictionary = [kSecGuestAttributePid: pid]
    var dynamicCode: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &dynamicCode) == errSecSuccess,
          let dynamicCode
    else { throw CalibrationError.invalid("cannot retain emitter dynamic code") }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
          let staticCode
    else { throw CalibrationError.invalid("cannot retain emitter static code") }
    var pathStaticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: kernelPath) as CFURL, [], &pathStaticCode)
        == errSecSuccess,
        let pathStaticCode
    else { throw CalibrationError.invalid("cannot retain emitter on-disk static code") }
    var informationValue: CFDictionary?
    let infoFlags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
    guard SecCodeCopySigningInformation(staticCode, infoFlags, &informationValue) == errSecSuccess,
          let information = informationValue as? [String: Any],
          let teamID = information[kSecCodeInfoTeamIdentifier as String] as? String,
          let cdhash = information[kSecCodeInfoUnique as String] as? Data,
          cdhash.count == 20,
          let signingIdentifier = information[kSecCodeInfoIdentifier as String] as? String,
          let signedExecutable = information[kSecCodeInfoMainExecutable as String] as? URL,
          canonicalPath(signedExecutable.path) == kernelPath,
          let requirement = appleRequirement(teamID: teamID),
          SecCodeCheckValidity(dynamicCode, [], requirement) == errSecSuccess,
          SecStaticCodeCheckValidity(
              pathStaticCode,
              SecCSFlags(rawValue: UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckAllArchitectures)),
              requirement) == errSecSuccess,
          let liveCDHashBefore = liveCodeSignatureHash(pid: pid),
          liveCDHashBefore == cdhash
    else { throw CalibrationError.invalid("emitter lacks one Apple-anchored Team/CDHash identity") }
    var pathInformationValue: CFDictionary?
    guard SecCodeCopySigningInformation(pathStaticCode, infoFlags, &pathInformationValue) == errSecSuccess,
          let pathInformation = pathInformationValue as? [String: Any],
          pathInformation[kSecCodeInfoTeamIdentifier as String] as? String == teamID,
          pathInformation[kSecCodeInfoUnique as String] as? Data == cdhash,
          pathInformation[kSecCodeInfoIdentifier as String] as? String == signingIdentifier,
          let pathExecutable = pathInformation[kSecCodeInfoMainExecutable as String] as? URL,
          canonicalPath(pathExecutable.path) == kernelPath
    else { throw CalibrationError.invalid("emitter live and on-disk code identities differ") }

    var after = stat()
    var pathInfo = stat()
    guard fstat(descriptor, &after) == 0,
          lstat(kernelPath, &pathInfo) == 0,
          before.st_dev == after.st_dev, before.st_ino == after.st_ino,
          before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          after.st_dev == pathInfo.st_dev, after.st_ino == pathInfo.st_ino,
          liveCodeSignatureHash(pid: pid) == cdhash,
          processStartIdentity(pid: pid).map(String.init) == startBefore
    else { throw CalibrationError.invalid("emitter identity changed during authentication") }

    return CodeIdentity(
        pid: pid,
        startIdentity: startBefore,
        executablePath: kernelPath,
        executableSHA256: executableDigest,
        teamID: teamID,
        codeSignatureHash: hex(cdhash),
        signingIdentifier: signingIdentifier,
        appleAnchored: true)
}

private func exactTarget(pid: Int32, startIdentity: String, windowID: UInt32) throws -> TargetReceipt {
    guard processStartIdentity(pid: pid).map(String.init) == startIdentity,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    else { throw CalibrationError.invalid("controlled target process is not the exact frontmost generation") }
    let requested = CGWindowListCopyWindowInfo(
        [.optionIncludingWindow, .excludeDesktopElements],
        windowID) as? [[String: Any]] ?? []
    guard requested.count == 1,
          (requested[0][kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
          (requested[0][kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID,
          (requested[0][kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
          let dictionary = requested[0][kCGWindowBounds as String] as? NSDictionary,
          let rectangle = CGRect(dictionaryRepresentation: dictionary),
          rectangle.width > 0, rectangle.height > 0
    else { throw CalibrationError.invalid("controlled target window is not one visible layer-zero exact window") }
    let targetWindows = (CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] ?? []).filter {
        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
            ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    }
    guard (targetWindows.first?[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID,
          processStartIdentity(pid: pid).map(String.init) == startIdentity
    else { throw CalibrationError.invalid("controlled target is not its process's exact frontmost window") }
    return TargetReceipt(
        pid: pid,
        startIdentity: startIdentity,
        windowID: windowID,
        bounds: Bounds(
            x: rectangle.origin.x,
            y: rectangle.origin.y,
            width: rectangle.width,
            height: rectangle.height))
}

private func privateOutputParent(_ outputPath: String) throws {
    guard outputPath.hasPrefix("/"), !FileManager.default.fileExists(atPath: outputPath) else {
        throw CalibrationError.invalid("output must be one absent absolute path")
    }
    let parent = URL(fileURLWithPath: outputPath).deletingLastPathComponent().path
    var info = stat()
    guard lstat(parent, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFDIR,
          (info.st_mode & 0o077) == 0,
          info.st_uid == geteuid(),
          canonicalPath(parent) == parent
    else { throw CalibrationError.invalid("output parent must be one canonical owner-private directory") }
}

private func writeReceipt(_ receipt: some Encodable, to outputPath: String) throws {
    try privateOutputParent(outputPath)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(receipt)
    data.append(0x0A)
    let temporaryPath = "\(outputPath).tmp.\(getpid()).\(UUID().uuidString)"
    let descriptor = open(
        temporaryPath,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600)
    guard descriptor >= 0 else {
        throw CalibrationError.invalid("cannot create private receipt staging file")
    }
    var descriptorIsOpen = true
    var published = false
    defer {
        if descriptorIsOpen {
            close(descriptor)
        }
        if !published {
            unlink(temporaryPath)
        }
    }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let result = Darwin.write(
                descriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset)
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else {
                throw CalibrationError.invalid("cannot write complete receipt staging bytes")
            }
            offset += result
        }
    }
    var stagedInfo = stat()
    guard fsync(descriptor) == 0,
          fstat(descriptor, &stagedInfo) == 0,
          close(descriptor) == 0
    else { throw CalibrationError.invalid("cannot commit receipt staging bytes") }
    descriptorIsOpen = false
    let renameResult = temporaryPath.withCString { source in
        outputPath.withCString { destination in
            renameatx_np(
                AT_FDCWD,
                source,
                AT_FDCWD,
                destination,
                UInt32(RENAME_EXCL))
        }
    }
    guard renameResult == 0 else {
        throw CalibrationError.invalid(
            errno == EEXIST ? "output receipt already exists" : "cannot publish output receipt exclusively")
    }
    published = true
    let parent = URL(fileURLWithPath: outputPath).deletingLastPathComponent().path
    let parentDescriptor = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parentDescriptor >= 0 else {
        throw CalibrationError.invalid("cannot open receipt parent for synchronization")
    }
    defer { close(parentDescriptor) }
    guard fsync(parentDescriptor) == 0 else {
        throw CalibrationError.invalid("cannot synchronize receipt parent")
    }
    let publishedDescriptor = open(outputPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard publishedDescriptor >= 0 else {
        throw CalibrationError.invalid("cannot reopen published receipt")
    }
    defer { close(publishedDescriptor) }
    var publishedInfo = stat()
    guard fstat(publishedDescriptor, &publishedInfo) == 0,
          (publishedInfo.st_mode & S_IFMT) == S_IFREG,
          (publishedInfo.st_mode & 0o777) == 0o600,
          publishedInfo.st_nlink == 1,
          publishedInfo.st_uid == geteuid(),
          publishedInfo.st_dev == stagedInfo.st_dev,
          publishedInfo.st_ino == stagedInfo.st_ino,
          publishedInfo.st_size == data.count
    else { throw CalibrationError.invalid("published receipt identity is invalid") }
    let handle = FileHandle(fileDescriptor: publishedDescriptor, closeOnDealloc: false)
    guard try (handle.readToEnd()) == data else {
        throw CalibrationError.invalid("published receipt bytes differ from staging")
    }
}

private func option(_ name: String, arguments: [String]) throws -> String {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        throw CalibrationError.invalid("missing \(name)")
    }
    return arguments[index + 1]
}

private func parseArguments(_ raw: [String]) throws -> Arguments {
    let names = [
        "--target-pid",
        "--target-start-identity",
        "--target-window-id",
        "--timeout-seconds",
        "--settle-milliseconds",
        "--output",
    ]
    guard raw.count == names.count * 2,
          stride(from: 0, to: raw.count, by: 2).allSatisfy({ names.contains(raw[$0]) }),
          Set(stride(from: 0, to: raw.count, by: 2).map { raw[$0] }).count == names.count,
          let targetPID = try Int32(option("--target-pid", arguments: raw)), targetPID > 0,
          let targetWindowID = try UInt32(option("--target-window-id", arguments: raw)), targetWindowID > 0,
          let timeoutSeconds = try Int(option("--timeout-seconds", arguments: raw)), (5...120).contains(timeoutSeconds),
          let settleMilliseconds = try Int(option("--settle-milliseconds", arguments: raw)),
          (100...3000).contains(settleMilliseconds)
    else { throw CalibrationError.invalid("arguments are not one closed bounded calibration request") }
    let startIdentity = try option("--target-start-identity", arguments: raw)
    guard !startIdentity.isEmpty, startIdentity.allSatisfy(\.isNumber), startIdentity.first != "0" else {
        throw CalibrationError.invalid("target start identity is not canonical decimal")
    }
    return try Arguments(
        targetPID: targetPID,
        targetStartIdentity: startIdentity,
        targetWindowID: targetWindowID,
        timeoutSeconds: timeoutSeconds,
        settleMilliseconds: settleMilliseconds,
        outputPath: option("--output", arguments: raw))
}

private func runCalibration(_ arguments: Arguments) throws {
    _ = try exactTarget(
        pid: arguments.targetPID,
        startIdentity: arguments.targetStartIdentity,
        windowID: arguments.targetWindowID)
    let state = EventState()
    let retainedState = Unmanaged.passRetained(state)
    defer { retainedState.release() }
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: eventMask(),
        callback: eventCallback,
        userInfo: retainedState.toOpaque())
    else { throw CalibrationError.invalid("passive event tap is unavailable; Input Monitoring may be denied") }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
    CGEvent.tapEnable(tap: tap, enable: true)
    defer {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
    }

    let deadline = Date().addingTimeInterval(TimeInterval(arguments.timeoutSeconds))
    var firstSeenAt: Date?
    var beforeIdentity: CodeIdentity?
    while Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        let events = state.snapshot()
        if events
            .count > 1
        {
            throw CalibrationError.invalid("more than one eligible integrated-CU event was observed")
        }
        if let event = events.first {
            guard event.sourcePID > 0,
                  event.sourcePID != getpid(),
                  event.sourcePID != arguments.targetPID,
                  !event.sourceStartIdentityAtCallback.isEmpty
            else { throw CalibrationError.invalid("event source PID is not an independent live emitter") }
            if beforeIdentity == nil {
                beforeIdentity = try codeIdentity(
                    pid: event.sourcePID,
                    expectedStartIdentity: event.sourceStartIdentityAtCallback)
                firstSeenAt = Date()
            }
            if let firstSeenAt,
               Date().timeIntervalSince(firstSeenAt) * 1000 >= Double(arguments.settleMilliseconds)
            {
                break
            }
        }
    }
    let events = state.snapshot()
    guard events.count == 1, let event = events.first, let beforeIdentity else {
        throw CalibrationError.invalid("timed out without exactly one eligible integrated-CU event")
    }
    let afterIdentity = try codeIdentity(
        pid: event.sourcePID,
        expectedStartIdentity: event.sourceStartIdentityAtCallback)
    guard beforeIdentity == afterIdentity else {
        throw CalibrationError.invalid("emitter Apple/process/executable identity changed across calibration")
    }
    let targetAfter = try exactTarget(
        pid: arguments.targetPID,
        startIdentity: arguments.targetStartIdentity,
        windowID: arguments.targetWindowID)
    try writeReceipt(CalibrationReceipt(
        version: 1,
        eventCount: 1,
        settleMilliseconds: arguments.settleMilliseconds,
        target: targetAfter,
        capturedEvent: event,
        before: beforeIdentity,
        after: afterIdentity), to: arguments.outputPath)
}

private func runSelfTest() throws {
    guard eligibleTypes.contains(.leftMouseDown),
          eligibleTypes.contains(.keyDown),
          eligibleTypes.contains(.scrollWheel),
          !eligibleTypes.contains(.mouseMoved),
          !eligibleTypes.contains(.leftMouseUp),
          eventTypeName(.otherMouseDown) == "other_mouse_down",
          appleRequirement(teamID: "FWJYW4S8P8") != nil,
          appleRequirement(teamID: "unsafe-team") == nil
    else { throw CalibrationError.invalid("self-test failed") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(SelfTestReceipt(success: true, tests: 8))
    FileHandle.standardOutput.write(bytes)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func runPublicationSelfTest(outputPath: String) throws {
    try writeReceipt(SelfTestReceipt(success: true, tests: 1), to: outputPath)
}

do {
    let rawArguments = Array(CommandLine.arguments.dropFirst())
    if rawArguments == ["--self-test"] {
        try runSelfTest()
    } else if rawArguments.count == 2, rawArguments[0] == "--self-test-output" {
        try runPublicationSelfTest(outputPath: rawArguments[1])
    } else {
        try runCalibration(parseArguments(rawArguments))
    }
} catch {
    FileHandle.standardError.write(Data("integrated-cu-emitter-calibrator: \(error)\n".utf8))
    exit(1)
}
