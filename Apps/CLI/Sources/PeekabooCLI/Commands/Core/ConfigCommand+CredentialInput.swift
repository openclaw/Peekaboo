import Darwin
import Foundation

final nonisolated class ConfigCredentialPromptLease: @unchecked Sendable {
    private let lock: NSLock

    init(lock: NSLock) {
        self.lock = lock
    }

    deinit {
        self.lock.unlock()
    }
}

@MainActor
struct ConfigCredentialInput {
    static let maximumByteCount = 64 * 1024
    private nonisolated static let promptLock = NSLock()
    private static let promptBufferSentinel = CChar(bitPattern: 0xFF)

    struct Request {
        var legacyValue: String?
        var reference: String?
        var filePath: String?
        var readFromStdin = false
        var noInput = false
        var prompt: String
    }

    struct Resolution {
        enum Source: String {
            case reference
            case file
            case stdin
            case prompt
            case deprecatedArgument = "deprecated-argument"
        }

        let value: String
        let source: Source
    }

    struct IO {
        var isStdinTTY: () -> Bool
        var readStdin: () throws -> String
        var readFile: (String) throws -> String
        var promptWithoutEcho: (String) throws -> String
        var writeDiagnostic: (String) -> Void

        static var live: Self {
            Self(
                isStdinTTY: { isatty(STDIN_FILENO) == 1 },
                readStdin: { try ConfigCredentialInput.readAll(from: STDIN_FILENO) },
                readFile: { try ConfigCredentialInput.readSecureFile(at: $0) },
                promptWithoutEcho: { try ConfigCredentialInput.readPrompt(prompt: $0) },
                writeDiagnostic: { ConfigCredentialInput.write($0 + "\n", to: STDERR_FILENO) }
            )
        }
    }

    enum InputError: LocalizedError, Equatable {
        case conflictingSources
        case missingNonInteractiveInput
        case emptyValue
        case multilineValue
        case valueTooLarge
        case invalidReference
        case fileOpenFailed(String)
        case insecureFile(String)
        case inputReadFailed
        case terminalUnavailable

        var errorDescription: String? {
            switch self {
            case .conflictingSources:
                "Choose exactly one credential source: a prompt, --credential-stdin, --credential-file, " +
                    "--credential-ref, or the deprecated argv value."
            case .missingNonInteractiveInput:
                "Credential input is required. Pipe it to --credential-stdin, use --credential-file, or omit " +
                    "--no-input to use the secure prompt."
            case .emptyValue:
                "Credential input must not be empty; pipe one line to --credential-stdin or use --credential-file."
            case .multilineValue:
                "Credential input must contain exactly one line."
            case .valueTooLarge:
                "Credential input exceeds the 64 KiB limit."
            case .invalidReference:
                "Credential references must use the non-secret ${NAME} form."
            case let .fileOpenFailed(path):
                "Unable to read credential file '\(path)'."
            case let .insecureFile(path):
                "Credential file '\(path)' must be a regular file owned by the current user, owner-readable, " +
                    "inaccessible to group and other users (mode 0400 or 0600), and free of extended ACL entries."
            case .inputReadFailed:
                "Unable to read credential input."
            case .terminalUnavailable:
                "Unable to disable terminal echo for secure credential input."
            }
        }
    }

    static func resolve(_ request: Request, io: IO = .live) throws -> Resolution {
        let explicitSourceCount = [
            request.legacyValue != nil,
            request.reference != nil,
            request.filePath != nil,
            request.readFromStdin,
        ].count(where: { $0 })
        guard explicitSourceCount <= 1 else {
            throw InputError.conflictingSources
        }

        if let legacyValue = request.legacyValue {
            io.writeDiagnostic(
                "warning: passing credentials in argv is deprecated because process listings may expose them; " +
                    "use --credential-stdin, --credential-file, or the secure prompt"
            )
            return try Resolution(
                value: self.normalized(legacyValue),
                source: .deprecatedArgument
            )
        }

        if let reference = request.reference {
            guard self.isCredentialReference(reference) else {
                throw InputError.invalidReference
            }
            return Resolution(value: reference, source: .reference)
        }

        if let filePath = request.filePath {
            return try Resolution(value: self.normalized(io.readFile(filePath)), source: .file)
        }

        if request.readFromStdin {
            if io.isStdinTTY() {
                guard !request.noInput else {
                    throw InputError.missingNonInteractiveInput
                }
                return try Resolution(
                    value: self.normalized(io.promptWithoutEcho(request.prompt)),
                    source: .prompt
                )
            }
            return try Resolution(value: self.normalized(io.readStdin()), source: .stdin)
        }

        if !io.isStdinTTY() {
            return try Resolution(value: self.normalized(io.readStdin()), source: .stdin)
        }

        guard !request.noInput else {
            throw InputError.missingNonInteractiveInput
        }

        return try Resolution(value: self.normalized(io.promptWithoutEcho(request.prompt)), source: .prompt)
    }

    static func isCredentialReference(_ value: String) -> Bool {
        guard value.hasPrefix("${"), value.hasSuffix("}") else { return false }
        let name = String(value.dropFirst(2).dropLast())
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    nonisolated static func acquirePromptLease() -> ConfigCredentialPromptLease? {
        guard self.promptLock.try() else { return nil }
        return ConfigCredentialPromptLease(lock: self.promptLock)
    }

    private static func readPrompt(prompt: String) throws -> String {
        guard let promptLease = self.acquirePromptLease() else {
            throw InputError.terminalUnavailable
        }
        defer { withExtendedLifetime(promptLease) {} }
        try self.verifyControllingTerminal()

        var rawBuffer = [CChar](repeating: 0, count: self.maximumByteCount + 2)
        return try prompt.withCString { promptPointer in
            try self.readAndValidatePromptBuffer(&rawBuffer) { buffer, capacity in
                readpassphrase(promptPointer, buffer, capacity, RPP_REQUIRE_TTY) != nil
            }
        }
    }

    static func readAndValidatePromptBuffer(
        _ rawBuffer: inout [CChar],
        read: (UnsafeMutablePointer<CChar>, Int) -> Bool
    ) throws -> String {
        rawBuffer.withUnsafeMutableBufferPointer { buffer in
            for index in buffer.indices {
                buffer[index] = self.promptBufferSentinel
            }
        }
        defer {
            rawBuffer.withUnsafeMutableBytes { bytes in
                _ = memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
            }
        }

        let nativeResult = rawBuffer.withUnsafeMutableBufferPointer { buffer in
            read(buffer.baseAddress!, buffer.count)
        }
        guard nativeResult else { throw InputError.terminalUnavailable }

        let firstTerminator = rawBuffer.withUnsafeBufferPointer { buffer in
            strnlen(buffer.baseAddress!, buffer.count)
        }
        guard let finalTerminator = rawBuffer.lastIndex(of: 0),
              rawBuffer[(finalTerminator + 1)...].allSatisfy({ $0 == self.promptBufferSentinel }),
              firstTerminator == finalTerminator
        else {
            throw InputError.multilineValue
        }
        guard finalTerminator <= self.maximumByteCount else { throw InputError.valueTooLarge }

        let value = rawBuffer.withUnsafeBufferPointer { buffer in
            String(validatingCString: buffer.baseAddress!)
        }
        guard let value else {
            throw InputError.inputReadFailed
        }
        return value
    }

    private static func verifyControllingTerminal() throws {
        // Mirror readpassphrase's required access without mutating terminal state during preflight.
        let fileDescriptor = Darwin.open("/dev/tty", O_RDWR | O_CLOEXEC | O_NOCTTY)
        guard fileDescriptor >= 0 else { throw InputError.terminalUnavailable }
        defer { close(fileDescriptor) }

        var metadata = stat()
        var terminal = termios()
        guard fstat(fileDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFCHR,
              isatty(fileDescriptor) == 1,
              tcgetattr(fileDescriptor, &terminal) == 0,
              tcgetpgrp(fileDescriptor) == getpgrp()
        else {
            throw InputError.terminalUnavailable
        }
    }

    static func readLine(from fileDescriptor: Int32) throws -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(128)

        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(fileDescriptor, &byte, 1)
            if count == 1 {
                if byte == UInt8(ascii: "\n") {
                    break
                }
                bytes.append(byte)
                guard bytes.count <= self.maximumByteCount else {
                    throw InputError.valueTooLarge
                }
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw InputError.inputReadFailed
        }

        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw InputError.inputReadFailed
        }
        return value
    }

    private static func readAll(from fileDescriptor: Int32) throws -> String {
        let bytes = try self.readBytes(from: fileDescriptor)
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw InputError.inputReadFailed
        }
        return value
    }

    static func readSecureFile(at path: String) throws -> String {
        let fileDescriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fileDescriptor >= 0 else {
            if errno == ELOOP {
                throw InputError.insecureFile(path)
            }
            throw InputError.fileOpenFailed(path)
        }
        defer { Darwin.close(fileDescriptor) }

        return try self.readSecureFile(fileDescriptor: fileDescriptor, displayPath: path)
    }

    static func readSecureFile(fileDescriptor: Int32, displayPath path: String) throws -> String {
        var metadata = stat()
        guard fstat(fileDescriptor, &metadata) == 0 else {
            throw InputError.fileOpenFailed(path)
        }

        let fileType = metadata.st_mode & mode_t(S_IFMT)
        let ownerPermissions = metadata.st_mode & mode_t(0o700)
        let groupOrOtherPermissions = metadata.st_mode & mode_t(0o077)
        guard fileType == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              ownerPermissions == mode_t(0o400) || ownerPermissions == mode_t(0o600),
              groupOrOtherPermissions == 0
        else {
            throw InputError.insecureFile(path)
        }
        guard try !self.hasExtendedACLEntries(fileDescriptor: fileDescriptor, displayPath: path) else {
            throw InputError.insecureFile(path)
        }

        let bytes = try self.readBytes(from: fileDescriptor)
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw InputError.inputReadFailed
        }
        return value
    }

    private static func hasExtendedACLEntries(fileDescriptor: Int32, displayPath path: String) throws -> Bool {
        errno = 0
        guard let accessControlList = acl_get_fd_np(fileDescriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return false
            }
            throw InputError.insecureFile(path)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(accessControlList)) }

        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(accessControlList, ACL_FIRST_ENTRY.rawValue, &entry)
        if result == 0 {
            return true
        }
        guard errno == EINVAL else {
            throw InputError.insecureFile(path)
        }
        return false
    }

    private static func readBytes(from fileDescriptor: Int32) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(256)
        var buffer = [UInt8](repeating: 0, count: 4096)

        while result.count <= self.maximumByteCount {
            let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw InputError.inputReadFailed
        }

        guard result.count <= self.maximumByteCount else {
            throw InputError.valueTooLarge
        }
        return result
    }

    private static func normalized(_ rawValue: String) throws -> String {
        guard rawValue.utf8.count <= self.maximumByteCount else {
            throw InputError.valueTooLarge
        }

        var value = rawValue
        if value.hasSuffix("\n") {
            value.removeLast()
            if value.hasSuffix("\r") {
                value.removeLast()
            }
        }

        guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            throw InputError.multilineValue
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InputError.emptyValue
        }
        return value
    }

    private static func write(_ value: String, to fileDescriptor: Int32) {
        let bytes = Array(value.utf8)
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    fileDescriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }
}

enum ConfigCredentialOutputRedactor {
    static func redact(_ message: String, credential: String) -> String {
        guard !credential.isEmpty else { return message }
        return message.replacingOccurrences(of: credential, with: "[redacted]")
    }
}
