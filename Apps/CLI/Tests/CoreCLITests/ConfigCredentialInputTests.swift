import Darwin
import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.unit))
struct ConfigCredentialInputTests {
    @Test
    func `piped stdin is selected without reflecting the credential`() throws {
        let credential = "fixture-secret-from-stdin"
        var diagnostics: [String] = []
        let resolution = try ConfigCredentialInput.resolve(
            .init(
                legacyValue: nil,
                reference: nil,
                filePath: nil,
                readFromStdin: true,
                noInput: true,
                prompt: "Credential: "
            ),
            io: .init(
                isStdinTTY: { false },
                readStdin: { credential + "\n" },
                readFile: { _ in Issue.record("Unexpected file read"); return "" },
                promptWithoutEcho: { _ in Issue.record("Unexpected prompt"); return "" },
                writeDiagnostic: { diagnostics.append($0) }
            )
        )

        #expect(resolution.value == credential)
        #expect(resolution.source == .stdin)
        #expect(diagnostics.isEmpty)
    }

    @Test
    func `no input rejects A missing TTY credential without prompting`() {
        var prompted = false
        let io = ConfigCredentialInput.IO(
            isStdinTTY: { true },
            readStdin: { Issue.record("Unexpected stdin read"); return "" },
            readFile: { _ in Issue.record("Unexpected file read"); return "" },
            promptWithoutEcho: { _ in prompted = true; return "should-not-be-read" },
            writeDiagnostic: { _ in }
        )

        #expect(throws: ConfigCredentialInput.InputError.missingNonInteractiveInput) {
            try ConfigCredentialInput.resolve(
                .init(
                    legacyValue: nil,
                    reference: nil,
                    filePath: nil,
                    readFromStdin: false,
                    noInput: true,
                    prompt: "Credential: "
                ),
                io: io
            )
        }
        #expect(prompted == false)

        #expect(throws: ConfigCredentialInput.InputError.missingNonInteractiveInput) {
            try ConfigCredentialInput.resolve(
                .init(
                    legacyValue: nil,
                    reference: nil,
                    filePath: nil,
                    readFromStdin: true,
                    noInput: true,
                    prompt: "Credential: "
                ),
                io: io
            )
        }
        #expect(prompted == false)
    }

    @Test
    func `interactive input uses the no echo prompt`() throws {
        var prompts: [String] = []
        let resolution = try ConfigCredentialInput.resolve(
            .init(
                legacyValue: nil,
                reference: nil,
                filePath: nil,
                readFromStdin: false,
                noInput: false,
                prompt: "Credential for fixture: "
            ),
            io: .init(
                isStdinTTY: { true },
                readStdin: { Issue.record("Unexpected stdin read"); return "" },
                readFile: { _ in Issue.record("Unexpected file read"); return "" },
                promptWithoutEcho: { prompt in
                    prompts.append(prompt)
                    return "fixture-secret-from-prompt"
                },
                writeDiagnostic: { _ in }
            )
        )

        #expect(resolution.source == .prompt)
        #expect(prompts == ["Credential for fixture: "])
    }

    @Test
    func `credential prompt gate permits only one active reader`() {
        var firstLease = ConfigCredentialInput.acquirePromptLease()
        #expect(firstLease != nil)
        #expect(ConfigCredentialInput.acquirePromptLease() == nil)
        firstLease = nil
        #expect(ConfigCredentialInput.acquirePromptLease() != nil)
    }

    @Test
    func `validated prompt buffer is wiped after copying`() throws {
        let fixture = "fixture-secret-buffer-wipe"
        var rawBuffer = [CChar](repeating: 0, count: ConfigCredentialInput.maximumByteCount + 2)
        let value = try ConfigCredentialInput.readAndValidatePromptBuffer(&rawBuffer) { buffer, capacity in
            let bytes = Array(fixture.utf8)
            guard bytes.count + 1 < capacity else { return false }
            for (index, byte) in bytes.enumerated() {
                buffer[index] = CChar(bitPattern: byte)
            }
            buffer[bytes.count] = 0
            return true
        }

        #expect(value == fixture)
        #expect(rawBuffer.allSatisfy { $0 == 0 })
    }

    @Test
    func `oversized prompt buffer is rejected and wiped`() {
        var rawBuffer = [CChar](repeating: 0, count: ConfigCredentialInput.maximumByteCount + 2)

        #expect(throws: ConfigCredentialInput.InputError.valueTooLarge) {
            try ConfigCredentialInput.readAndValidatePromptBuffer(&rawBuffer) { buffer, capacity in
                for index in 0...ConfigCredentialInput.maximumByteCount {
                    buffer[index] = CChar(bitPattern: UInt8(ascii: "x"))
                }
                buffer[capacity - 1] = 0
                return true
            }
        }
        #expect(rawBuffer.allSatisfy { $0 == 0 })
    }

    @Test
    func `embedded NUL prompt input is rejected and wiped`() {
        var rawBuffer = [CChar](repeating: 0, count: ConfigCredentialInput.maximumByteCount + 2)

        #expect(throws: ConfigCredentialInput.InputError.multilineValue) {
            try ConfigCredentialInput.readAndValidatePromptBuffer(&rawBuffer) { buffer, _ in
                buffer[0] = CChar(bitPattern: UInt8(ascii: "a"))
                buffer[1] = 0
                buffer[2] = CChar(bitPattern: UInt8(ascii: "b"))
                buffer[3] = 0
                return true
            }
        }
        #expect(rawBuffer.allSatisfy { $0 == 0 })
    }

    @Test
    func `invalid UTF-8 prompt input is rejected and wiped`() {
        var rawBuffer = [CChar](repeating: 0, count: ConfigCredentialInput.maximumByteCount + 2)

        #expect(throws: ConfigCredentialInput.InputError.inputReadFailed) {
            try ConfigCredentialInput.readAndValidatePromptBuffer(&rawBuffer) { buffer, _ in
                buffer[0] = CChar(bitPattern: 0xFF)
                buffer[1] = 0
                return true
            }
        }
        #expect(rawBuffer.allSatisfy { $0 == 0 })
    }

    @Test
    func `unterminated interactive input stops at the byte limit`() throws {
        let inputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-credential-limit-\(UUID().uuidString)")
        try Data(repeating: UInt8(ascii: "x"), count: ConfigCredentialInput.maximumByteCount + 1)
            .write(to: inputFile)
        defer { try? FileManager.default.removeItem(at: inputFile) }

        let fileDescriptor = inputFile.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        #expect(fileDescriptor >= 0)
        guard fileDescriptor >= 0 else { return }
        defer { close(fileDescriptor) }

        #expect(throws: ConfigCredentialInput.InputError.valueTooLarge) {
            try ConfigCredentialInput.readLine(from: fileDescriptor)
        }
    }

    @Test
    func `credential file requires owner only regular file permissions`() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-credential-input-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let secureFile = temporaryDirectory.appendingPathComponent("secure")
        try "fixture-secret-from-file\n".write(to: secureFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secureFile.path)

        let secureResolution = try ConfigCredentialInput.resolve(
            .init(
                legacyValue: nil,
                reference: nil,
                filePath: secureFile.path,
                readFromStdin: false,
                noInput: true,
                prompt: "Credential: "
            )
        )
        #expect(secureResolution.source == .file)
        #expect(secureResolution.value == "fixture-secret-from-file")

        let permissiveFile = temporaryDirectory.appendingPathComponent("permissive")
        try "fixture-secret-permissive\n".write(to: permissiveFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: permissiveFile.path)

        #expect(throws: ConfigCredentialInput.InputError.insecureFile(permissiveFile.path)) {
            try ConfigCredentialInput.resolve(
                .init(
                    legacyValue: nil,
                    reference: nil,
                    filePath: permissiveFile.path,
                    readFromStdin: false,
                    noInput: true,
                    prompt: "Credential: "
                )
            )
        }
    }

    @Test
    func `credential file rejects symlinks without reading the target`() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-credential-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let target = temporaryDirectory.appendingPathComponent("target")
        let link = temporaryDirectory.appendingPathComponent("link")
        try "fixture-secret-symlink-target\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: ConfigCredentialInput.InputError.insecureFile(link.path)) {
            try ConfigCredentialInput.resolve(
                .init(
                    legacyValue: nil,
                    reference: nil,
                    filePath: link.path,
                    readFromStdin: false,
                    noInput: true,
                    prompt: "Credential: "
                )
            )
        }
    }

    @Test
    func `credential file rejects an extended ACL that widens access`() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-credential-acl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let credentialFile = temporaryDirectory.appendingPathComponent("credential")
        try "fixture-secret-acl\n".write(to: credentialFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialFile.path)

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read", credentialFile.path]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)

        #expect(throws: ConfigCredentialInput.InputError.insecureFile(credentialFile.path)) {
            try ConfigCredentialInput.resolve(
                .init(
                    legacyValue: nil,
                    reference: nil,
                    filePath: credentialFile.path,
                    readFromStdin: false,
                    noInput: true,
                    prompt: "Credential: "
                )
            )
        }
    }

    @Test
    func `credential file reads the opened descriptor after a path swap`() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-credential-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let credentialPath = temporaryDirectory.appendingPathComponent("credential")
        let replacementPath = temporaryDirectory.appendingPathComponent("replacement")
        let openedPath = temporaryDirectory.appendingPathComponent("opened")
        try "fixture-secret-opened\n".write(to: credentialPath, atomically: true, encoding: .utf8)
        try "fixture-secret-replacement\n".write(to: replacementPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialPath.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacementPath.path)

        let fileDescriptor = credentialPath.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        #expect(fileDescriptor >= 0)
        guard fileDescriptor >= 0 else { return }
        defer { close(fileDescriptor) }

        try FileManager.default.moveItem(at: credentialPath, to: openedPath)
        try FileManager.default.moveItem(at: replacementPath, to: credentialPath)

        let value = try ConfigCredentialInput.readSecureFile(
            fileDescriptor: fileDescriptor,
            displayPath: credentialPath.path
        )
        #expect(value == "fixture-secret-opened\n")
        #expect(value != "fixture-secret-replacement\n")
    }

    @Test
    func `input sources are exclusive before any source is read`() {
        var didRead = false
        #expect(throws: ConfigCredentialInput.InputError.conflictingSources) {
            try ConfigCredentialInput.resolve(
                .init(
                    legacyValue: "deprecated-fixture-value",
                    reference: nil,
                    filePath: "/not/read",
                    readFromStdin: false,
                    noInput: true,
                    prompt: "Credential: "
                ),
                io: .init(
                    isStdinTTY: { true },
                    readStdin: { didRead = true; return "" },
                    readFile: { _ in didRead = true; return "" },
                    promptWithoutEcho: { _ in didRead = true; return "" },
                    writeDiagnostic: { _ in }
                )
            )
        }
        #expect(didRead == false)
    }

    @Test
    func `credential references accept only non secret variable syntax`() {
        #expect(ConfigCredentialInput.isCredentialReference("${OPENROUTER_API_KEY}"))
        #expect(ConfigCredentialInput.isCredentialReference("${_PRIVATE_KEY_2}"))
        #expect(!ConfigCredentialInput.isCredentialReference("literal-secret"))
        #expect(!ConfigCredentialInput.isCredentialReference("${2BAD}"))
        #expect(!ConfigCredentialInput.isCredentialReference("{env:LEGACY_KEY}"))
    }

    @Test
    func `legacy argv compatibility warns without reflecting the value`() throws {
        let credential = "fixture-secret-deprecated-argv"
        var diagnostics: [String] = []
        let resolution = try ConfigCredentialInput.resolve(
            .init(
                legacyValue: credential,
                reference: nil,
                filePath: nil,
                readFromStdin: false,
                noInput: true,
                prompt: "Credential: "
            ),
            io: .init(
                isStdinTTY: { true },
                readStdin: { "" },
                readFile: { _ in "" },
                promptWithoutEcho: { _ in "" },
                writeDiagnostic: { diagnostics.append($0) }
            )
        )

        #expect(resolution.source == .deprecatedArgument)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].contains("deprecated"))
        #expect(!diagnostics[0].contains(credential))
    }

    @Test
    func `credential values are redacted from downstream errors`() {
        let credential = "fixture-secret-reflected-by-provider"
        let message = ConfigCredentialOutputRedactor.redact(
            "Provider rejected \(credential)",
            credential: credential
        )
        #expect(message == "Provider rejected [redacted]")
        #expect(!message.contains(credential))
    }

    @Test
    func `raw credential keys reject file injection characters`() {
        #expect(ConfigCommand.CredentialSetCommand.isValidRawCredentialKey("CUSTOM_PROVIDER.KEY-1"))
        #expect(!ConfigCommand.CredentialSetCommand.isValidRawCredentialKey("BAD=INJECTED"))
        #expect(!ConfigCommand.CredentialSetCommand.isValidRawCredentialKey("BAD\nINJECTED"))
        #expect(!ConfigCommand.CredentialSetCommand.isValidRawCredentialKey(" BAD"))
    }

    @Test
    func `help recommends secure sources and labels argv compatibility deprecated`() {
        let credentialHelp = ConfigCommand.CredentialSetCommand.helpMessage()
        #expect(credentialHelp.contains("--credential-stdin"))
        #expect(credentialHelp.contains("--credential-file"))
        #expect(credentialHelp.contains("--no-input"))
        #expect(credentialHelp.contains("Deprecated credential value in argv"))

        let providerHelp = ConfigCommand.AddProviderCommand.helpMessage()
        #expect(providerHelp.contains("--credential-ref"))
        #expect(providerHelp.contains("--credential-stdin"))
        #expect(providerHelp.contains("--credential-file"))
        #expect(providerHelp.contains("Deprecated API key or reference in argv"))
    }
}
