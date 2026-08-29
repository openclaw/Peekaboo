import Commander
import Darwin
import Foundation
import MCP
import PeekabooCore
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooBridge
@testable import PeekabooCLI

struct BrowserHandoffCLITests {
    private struct InvalidBrowserInput {
        let action: String
        let handoffs: [String]
        let sockets: [String]
        let flags: Set<String>
        let expectedMessage: String
    }

    @Test
    @MainActor
    func `browser and MCP help expose only the explicit handoff file workflow`() throws {
        let browserHelp = BrowserCommand.helpMessage()
        let mcpHelp = MCPCommand.Serve.helpMessage()

        #expect(browserHelp.contains("--handoff-file"))
        #expect(browserHelp.contains("Atomically create one signed browser handoff receipt"))
        #expect(browserHelp.contains("Default mode therefore exposes only source-audited routes"))
        #expect(browserHelp.contains("reports those calls as background browser-protocol delivery"))
        #expect(browserHelp.contains("require explicit --foreground"))
        #expect(browserHelp.contains("and report foreground browser-protocol delivery"))
        #expect(browserHelp.contains(
            "Default calls still require an existing exact connection and never ambiently auto-connect"
        ))
        #expect(browserHelp.contains("only standalone CLI page actions may"))
        #expect(browserHelp.contains("standalone CLI auto-connect"))
        #expect(mcpHelp.contains("--browser-handoff"))
        #expect(mcpHelp.contains("Consume one signed browser handoff receipt into this server's scoped child"))

        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let invocation = try Program(descriptors: descriptors.map(\.metadata)).resolve(argv: [
            "peekaboo", "mcp", "serve",
            "--browser-handoff", "/private/tmp/handoff.json",
            "--bridge-socket", "/private/tmp/bridge.sock",
        ])
        #expect(invocation.parsedValues.options["browserHandoff"] == ["/private/tmp/handoff.json"])
        #expect(invocation.parsedValues.options["bridge-socket"] == ["/private/tmp/bridge.sock"])
    }

    @Test
    @MainActor
    func `browser handoff requires connect foreground one exact socket and one absolute destination`() throws {
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handoff = directory.appendingPathComponent("handoff.json").path
        let socket = "/private/tmp/peekaboo-handoff.sock"

        let valid = try Self.browserCommand(
            action: "connect",
            handoffValues: [handoff],
            socketValues: [socket],
            flags: ["foreground"]
        )
        #expect(throws: Never.self) { try valid.validateBeforeRuntime() }
        #expect(valid.runtimeOptions.requiresBrowserHandoffBridge)
        #expect(throws: ValidationError.self) {
            try valid.validateHandoffEnvironment(["PEEKABOO_NO_REMOTE": "1"])
        }
        #expect(throws: ValidationError.self) {
            try valid.validateHandoffEnvironment(["PEEKABOO_BRIDGE_SOCKET": "/private/tmp/other.sock"])
        }

        let cases = [
            InvalidBrowserInput(
                action: "connect",
                handoffs: [handoff],
                sockets: [socket],
                flags: [],
                expectedMessage: "requires --foreground"
            ),
            InvalidBrowserInput(
                action: "status",
                handoffs: [handoff],
                sockets: [socket],
                flags: ["foreground"],
                expectedMessage: "accepted only by browser connect"
            ),
            InvalidBrowserInput(
                action: "connect",
                handoffs: [handoff],
                sockets: [],
                flags: ["foreground"],
                expectedMessage: "requires exactly one --bridge-socket"
            ),
            InvalidBrowserInput(
                action: "connect",
                handoffs: ["relative.json"],
                sockets: [socket],
                flags: ["foreground"],
                expectedMessage: "path must be absolute"
            ),
            InvalidBrowserInput(
                action: "connect",
                handoffs: [handoff],
                sockets: [socket],
                flags: ["foreground", "no-remote"],
                expectedMessage: "does not support --no-remote"
            ),
        ]
        for testCase in cases {
            do {
                let command = try Self.browserCommand(
                    action: testCase.action,
                    handoffValues: testCase.handoffs,
                    socketValues: testCase.sockets,
                    flags: testCase.flags
                )
                try command.validateBeforeRuntime()
                Issue.record("Expected refusal containing \(testCase.expectedMessage)")
            } catch {
                #expect(error.localizedDescription.contains(testCase.expectedMessage))
            }
        }

        #expect(throws: ValidationError.self) {
            _ = try Self.browserCommand(
                action: "connect",
                handoffValues: [handoff, directory.appendingPathComponent("other.json").path],
                socketValues: [socket],
                flags: ["foreground"]
            )
        }
        #expect(throws: ValidationError.self) {
            _ = try Self.browserCommand(
                action: "connect",
                handoffValues: [handoff],
                socketValues: [socket, "/private/tmp/other.sock"],
                flags: ["foreground"]
            )
        }
    }

    @Test
    @MainActor
    func `hidden handoff request is command line only and never enters tool output`() async throws {
        let provider = HandoffToolFixtureBrowser()
        let arguments = ToolArguments(raw: [
            "action": "connect",
            "browser_url": "http://127.0.0.1:9222",
            "request_handoff": true,
        ])

        let mcpResponse = try await BrowserTool(
            client: provider,
            executionPolicy: .foregroundAllowed,
            instructionAudience: .mcp
        ).execute(arguments: arguments)
        #expect(mcpResponse.isError)
        #expect(provider.handoffConnectCount == 0)

        let cliResponse = try await BrowserTool(
            client: provider,
            executionPolicy: .foregroundAllowed,
            instructionAudience: .commandLine
        ).execute(arguments: arguments)
        #expect(!cliResponse.isError)
        #expect(provider.handoffConnectCount == 1)
        #expect(!String(describing: cliResponse).contains("private-handoff-bytes"))
        #expect(provider.takeConnectionHandoffReceiptBundleData() == Data("private-handoff-bytes".utf8))
        #expect(provider.takeConnectionHandoffReceiptBundleData() == nil)
    }

    @Test
    @MainActor
    func `handoff publication failure disconnects the reserved browser target`() async throws {
        let receipt = try await Self.canonicalHandoffData()
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("handoff.json")
        let provider = HandoffToolFixtureBrowser(handoffPayload: receipt)
        var command = try Self.browserCommand(
            action: "connect",
            handoffValues: [destination.path],
            socketValues: ["/private/tmp/peekaboo-handoff.sock"],
            flags: ["foreground"]
        )
        try command.validateBeforeRuntime()
        try Data("occupied".utf8).write(to: destination)
        let runtime = CommandRuntime(
            options: command.runtimeOptions,
            services: Self.services(browser: provider)
        )

        await #expect(throws: ExitCode.self) {
            try await command.run(using: runtime)
        }

        #expect(provider.handoffConnectCount == 1)
        #expect(provider.disconnectResultCount == 1)
        #expect(provider.takeConnectionHandoffReceiptBundleData() == nil)
    }

    @Test
    @MainActor
    func `store atomically publishes and stably reloads canonical mode 0600 bytes`() async throws {
        let fixture = try await Self.canonicalHandoffData()
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BrowserHandoffReceiptStore(fileURL: directory.appendingPathComponent("handoff.json"))

        try store.validateCanSave()
        try store.save(fixture)
        #expect(try store.load() == fixture)
        var info = stat()
        #expect(lstat(store.fileURL.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFREG)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_uid == geteuid())
        #expect(info.st_nlink == 1)
        #expect(throws: BrowserHandoffReceiptStoreError.alreadyExists) { try store.validateCanSave() }
        #expect(throws: BrowserHandoffReceiptStoreError.alreadyExists) { try store.save(fixture) }
        #expect(try store.load() == fixture)
    }

    @Test
    @MainActor
    func `store rejects intermediate symlinks and parent chain substitution after preflight`() async throws {
        let fixture = try await Self.canonicalHandoffData()

        do {
            let container = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: container) }
            let realParent = container.appendingPathComponent("real", isDirectory: true)
            try Self.createPrivateDirectory(at: realParent)
            let linkedParent = container.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
            let store = try BrowserHandoffReceiptStore(
                fileURL: linkedParent.appendingPathComponent("handoff.json")
            )

            #expect(throws: BrowserHandoffReceiptStoreError.unsafePath(
                "parent path components must be existing non-symbolic-link directories"
            )) { try store.validateCanSave() }
        }

        do {
            let container = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: container) }
            let parent = container.appendingPathComponent("parent", isDirectory: true)
            let displaced = container.appendingPathComponent("displaced", isDirectory: true)
            try Self.createPrivateDirectory(at: parent)
            let store = try BrowserHandoffReceiptStore(fileURL: parent.appendingPathComponent("handoff.json"))
            try store.validateCanSave()

            try FileManager.default.moveItem(at: parent, to: displaced)
            try Self.createPrivateDirectory(at: parent)

            #expect(throws: BrowserHandoffReceiptStoreError.unsafePath(
                "parent directory or one of its ancestors changed after validation"
            )) { try store.save(fixture) }
            #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("handoff.json").path))
            #expect(!FileManager.default.fileExists(atPath: displaced.appendingPathComponent("handoff.json").path))
        }

        do {
            let container = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: container) }
            let ancestor = container.appendingPathComponent("ancestor", isDirectory: true)
            let parent = ancestor.appendingPathComponent("parent", isDirectory: true)
            let displaced = container.appendingPathComponent("displaced", isDirectory: true)
            try Self.createPrivateDirectory(at: ancestor)
            try Self.createPrivateDirectory(at: parent)
            let store = try BrowserHandoffReceiptStore(fileURL: parent.appendingPathComponent("handoff.json"))
            try store.validateCanSave()

            try FileManager.default.moveItem(at: ancestor, to: displaced)
            try Self.createPrivateDirectory(at: ancestor)
            try Self.createPrivateDirectory(at: parent)

            #expect(throws: BrowserHandoffReceiptStoreError.unsafePath(
                "parent directory or one of its ancestors changed after validation"
            )) { try store.save(fixture) }
            #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("handoff.json").path))
            let oldReceipt = displaced.appendingPathComponent("parent/handoff.json")
            #expect(!FileManager.default.fileExists(atPath: oldReceipt.path))
        }
    }

    @Test
    @MainActor
    func `browser command retains its validated parent binding until publication`() throws {
        let container = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let parent = container.appendingPathComponent("parent", isDirectory: true)
        let displaced = container.appendingPathComponent("displaced", isDirectory: true)
        try Self.createPrivateDirectory(at: parent)
        let destination = parent.appendingPathComponent("handoff.json")
        let command = try Self.browserCommand(
            action: "connect",
            handoffValues: [destination.path],
            socketValues: ["/private/tmp/peekaboo-handoff.sock"],
            flags: ["foreground"]
        )
        try command.validateBeforeRuntime()

        try FileManager.default.moveItem(at: parent, to: displaced)
        try Self.createPrivateDirectory(at: parent)

        #expect(throws: BrowserHandoffReceiptStoreError.unsafePath(
            "parent directory or one of its ancestors changed after validation"
        )) {
            try command.validateBeforeRuntime()
        }
    }

    @Test
    @MainActor
    func `store preserves final substitution and removes publication after ancestor swap`() async throws {
        let fixture = try await Self.canonicalHandoffData()

        do {
            let directory = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("handoff.json")
            let store = try BrowserHandoffReceiptStore(fileURL: destination)
            let blocker = Data("existing destination".utf8)

            #expect(throws: BrowserHandoffReceiptStoreError.alreadyExists) {
                try store.save(fixture) {
                    try blocker.write(to: destination)
                }
            }
            #expect(try Data(contentsOf: destination) == blocker)
            let temporaryNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix(".pbh-") }
            #expect(temporaryNames.isEmpty)
        }

        do {
            let container = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: container) }
            let ancestor = container.appendingPathComponent("ancestor", isDirectory: true)
            let parent = ancestor.appendingPathComponent("parent", isDirectory: true)
            let displaced = container.appendingPathComponent("displaced", isDirectory: true)
            try Self.createPrivateDirectory(at: ancestor)
            try Self.createPrivateDirectory(at: parent)
            let destination = parent.appendingPathComponent("handoff.json")
            let store = try BrowserHandoffReceiptStore(fileURL: destination)
            try store.validateCanSave()

            #expect(throws: BrowserHandoffReceiptStoreError.unsafePath(
                "parent directory or one of its ancestors changed after validation"
            )) {
                try store.save(fixture, afterPublication: {
                    try FileManager.default.moveItem(at: ancestor, to: displaced)
                    try Self.createPrivateDirectory(at: ancestor)
                    try Self.createPrivateDirectory(at: parent)
                })
            }

            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let displacedReceipt = displaced.appendingPathComponent("parent/handoff.json")
            #expect(!FileManager.default.fileExists(atPath: displacedReceipt.path))
        }
    }

    @Test
    @MainActor
    func `handoff path diagnostics reject unsafe paths`() async throws {
        let fixture = try await Self.canonicalHandoffData()

        do {
            let directory = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = directory.appendingPathComponent("target.json")
            let link = directory.appendingPathComponent("handoff.json")
            _ = try Self.cleanReceiptStore(fixture, at: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let store = try BrowserHandoffReceiptStore(fileURL: link)
            #expect(throws: BrowserHandoffReceiptStoreError.unsafePath("symbolic links are not accepted")) {
                try store.load()
            }
            #expect(throws: BrowserHandoffReceiptStoreError.alreadyExists) { try store.validateCanSave() }
        }

        do {
            let directory = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("handoff.json")
            let alias = directory.appendingPathComponent("alias.json")
            let store = try Self.cleanReceiptStore(fixture, at: file)
            try #require(link(file.path, alias.path) == 0)
            #expect(throws: BrowserHandoffReceiptStoreError.unsafePath(
                "file must be one owner-only regular file with mode 0600 and a bounded size"
            )) {
                try store.load()
            }
        }

        do {
            let directory = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("handoff.json")
            let store = try Self.cleanReceiptStore(fixture, at: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            #expect(throws: BrowserHandoffReceiptStoreError.unsafePath(
                "file must be one owner-only regular file with mode 0600 and a bounded size"
            )) {
                try store.load()
            }
        }

        do {
            let directory = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try BrowserHandoffReceiptStore(fileURL: directory.appendingPathComponent("handoff.json"))
            try store.validateCanSave()
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            #expect(throws: BrowserHandoffReceiptStoreError.unsafePath(
                "parent directory must be owned by the current user with mode 0700"
            )) {
                try store.validateCanSave()
            }
        }
    }

    @Test(arguments: BrowserHandoffPathSubject.allCases, [
        BrowserHandoffPathInspection.extendedACL, .extendedAttributes,
    ])
    @MainActor
    func `handoff path diagnostics reject metadata before runtime`(
        subject: BrowserHandoffPathSubject,
        inspection: BrowserHandoffPathInspection
    ) async throws {
        let fixture = try await Self.canonicalHandoffData()
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Self.cleanReceiptStore(fixture, at: directory.appendingPathComponent("handoff.json"))
        let url = subject == .parent ? directory : store.fileURL
        let expected: BrowserHandoffReceiptStoreError
        var privateValue: String?
        if inspection == .extendedACL {
            try Self.addReadableACL(to: url)
            expected = .extendedACL(subject)
        } else {
            privateValue = try Self.addExtendedAttribute(to: url)
            expected = .extendedAttributes(subject)
        }

        do {
            _ = try store.load()
            Issue.record("Expected the deliberately added metadata to be refused")
        } catch let error as BrowserHandoffReceiptStoreError {
            #expect(error == expected)
            let diagnostic = error.localizedDescription + (error.envelopeHint ?? "") + String(describing: error)
            // Assert only a Boolean so a failing test never prints the private fixture value.
            let disclosedValue = privateValue.map { diagnostic.contains($0) } ?? false
            #expect(!disclosedValue)
        }

        let inputError = BrowserHandoffCLIInputError.invalidReceipt(expected.localizedDescription)
        #expect(inputError.envelopeCode == .VALIDATION_ERROR)
        #expect(inputError.envelopeRetrySafe == true)
        #expect(inputError.envelopeMutationDispatched == false)
        #expect(inputError.envelopeHint?.contains("do not fall back") == true)
        var runtimeConstructed = false
        let factory = CommanderRuntimeExecutor.RuntimeFactory { _ in
            runtimeConstructed = true
            throw StopBeforeRuntimeConstruction()
        }
        await #expect(throws: inputError) {
            try await CommanderRuntimeExecutor.resolveAndRun(
                arguments: [
                    "peekaboo", "mcp", "serve",
                    "--browser-handoff", store.fileURL.path,
                    "--bridge-socket", "/private/tmp/peekaboo-handoff.sock",
                ],
                runtimeFactory: factory
            )
        }
        if subject == .parent {
            #expect(throws: expected) { try store.validateCanSave() }
            await #expect(throws: expected) {
                try await CommanderRuntimeExecutor.resolveAndRun(
                    arguments: [
                        "peekaboo", "browser", "connect", "--foreground",
                        "--handoff-file", directory.appendingPathComponent("unused.json").path,
                        "--bridge-socket", "/private/tmp/peekaboo-handoff.sock",
                    ],
                    runtimeFactory: factory
                )
            }
        }
        #expect(!runtimeConstructed)
    }

    @Test(arguments: BrowserHandoffPathSubject.allCases)
    func `handoff path diagnostics distinguish inspection failures`(subject: BrowserHandoffPathSubject) {
        #expect(throws: BrowserHandoffReceiptStoreError.inspectionFailed(subject, .extendedACL)) {
            try BrowserHandoffReceiptStore.requireNoExtendedACL(-1, subject: subject)
        }
        #expect(throws: BrowserHandoffReceiptStoreError.inspectionFailed(subject, .extendedAttributes)) {
            try BrowserHandoffReceiptStore.requireNoExtendedAttributes(-1, subject: subject)
        }
    }

    @Test(arguments: BrowserHandoffPathSubject.allCases)
    func `handoff path diagnostics keep distinct hints and envelope`(subject: BrowserHandoffPathSubject) {
        let attributes = BrowserHandoffReceiptStoreError.extendedAttributes(subject)
        let acl = BrowserHandoffReceiptStoreError.extendedACL(subject)
        #expect(attributes.errorDescription ==
            "Browser handoff \(subject.rawValue) is unsafe: extended attributes are not accepted.")
        #expect(acl.errorDescription ==
            "Browser handoff \(subject.rawValue) is unsafe: extended access controls are not accepted.")
        #expect(attributes.envelopeHint?.contains("zero extended attributes, including OS provenance") == true)
        #expect(attributes.envelopeHint?.contains("not compatible") == true)
        #expect(acl.envelopeHint?.contains("zero extended ACLs") == true)
        #expect(acl.envelopeHint?.contains("OS provenance") == false)

        let inspections = BrowserHandoffPathInspection.allCases.map {
            BrowserHandoffReceiptStoreError.inspectionFailed(subject, $0)
        }
        for error in inspections {
            #expect(error.errorDescription?.contains(subject.rawValue) == true)
            #expect(error.errorDescription?.contains("could not be inspected") == true)
            #expect(error.errorDescription?.contains("are not accepted") == false)
            #expect(error.envelopeHint?.contains("does not establish whether") == true)
            #expect(error.envelopeHint?.contains("OS provenance") == false)
        }
        for error in [attributes, acl] + inspections {
            #expect(error.envelopeCode == .FILE_IO_ERROR)
            #expect(error.envelopeEffect == nil)
            #expect(error.envelopeRetrySafe == true)
            #expect(error.envelopeMutationDispatched == false)
            #expect(error.envelopeHint?.contains("without fallback") == true)
            #expect(error.envelopeHint?.contains("Use a standardized absolute path") == false)
        }
        let unrelated = BrowserHandoffReceiptStoreError.unsafePath("extended attributes are not accepted")
        #expect(unrelated.envelopeHint?.contains("OS provenance") == false)
    }

    @Test
    @MainActor
    func `store rejects path substitution noncanonical bytes and oversized input`() async throws {
        let fixture = try await Self.canonicalHandoffData()
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("handoff.json")
        let displaced = directory.appendingPathComponent("displaced.json")
        let store = try BrowserHandoffReceiptStore(fileURL: file)
        try store.save(fixture)

        #expect(throws: BrowserHandoffReceiptStoreError.unsafePath("file changed while it was being read")) {
            try store.load {
                try FileManager.default.moveItem(at: file, to: displaced)
                try fixture.write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }

        var noncanonical = fixture
        noncanonical.append(UInt8(ascii: "\n"))
        #expect(throws: BrowserHandoffReceiptStoreError.invalidReceipt("receipt bundle bytes are not canonical")) {
            try BrowserHandoffReceiptStore.validateCanonicalReceipt(noncanonical)
        }
        let oversized = Data(
            repeating: UInt8(ascii: "x"),
            count: Int(BrowserHandoffReceiptStore.maximumReceiptBytes) + 1
        )
        #expect(throws: BrowserHandoffReceiptStoreError.invalidReceipt(
            "receipt must be nonempty and at most \(BrowserHandoffReceiptStore.maximumReceiptBytes) bytes"
        )) {
            try BrowserHandoffReceiptStore.validateCanonicalReceipt(oversized)
        }
        #expect(throws: BrowserHandoffReceiptStoreError.unsafePath(
            "path must be absolute, nonempty, and already in standardized component form"
        )) {
            _ = try BrowserHandoffReceiptStore(resolvingAbsolutePath: "relative.json")
        }

        let longNameDirectory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: longNameDirectory) }
        let longNameStore = try BrowserHandoffReceiptStore(
            fileURL: longNameDirectory.appendingPathComponent(String(repeating: "a", count: 255))
        )
        try longNameStore.validateCanSave()
        try longNameStore.save(fixture)
        #expect(try longNameStore.load() == fixture)
    }

    @Test
    @MainActor
    func `MCP input loads canonical bytes and rejects duplicate conflicting or local routing`() async throws {
        let fixture = try await Self.canonicalHandoffData()
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BrowserHandoffReceiptStore(fileURL: directory.appendingPathComponent("handoff.json"))
        try store.save(fixture)
        let socket = "/private/tmp/peekaboo-handoff.sock"
        let valid = ParsedValues(
            positional: [],
            options: [
                "browserHandoff": [store.fileURL.path],
                "bridge-socket": [socket],
            ],
            flags: []
        )

        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: valid,
            commandType: MCPCommand.Serve.self,
            environment: [:]
        )
        #expect(options.browserHandoffReceiptBundleData == fixture)
        #expect(options.bridgeSocketPath == socket)
        #expect(options.preferRemote)
        #expect(!options.remoteIsolationRequested)
        #expect(!options.autoStartDaemon)
        #expect(options.requiresBrowserHandoffBridge)
        let captureEnvironmentOptions = options.applyingEnvironmentOverrides(
            environment: ["PEEKABOO_CAPTURE_ENGINE": "classic"]
        )
        #expect(captureEnvironmentOptions.preferRemote)
        #expect(!captureEnvironmentOptions.remoteIsolationRequested)
        let runtime = CommandRuntime(options: options, services: PeekabooServices())
        #expect(runtime.browserHandoffReceiptBundleData == fixture)

        let invalidCases: [(ParsedValues, [String: String], BrowserHandoffCLIInputError)] = [
            (
                ParsedValues(
                    positional: [],
                    options: [
                        "browserHandoff": [store.fileURL.path, store.fileURL.path],
                        "bridge-socket": [socket],
                    ],
                    flags: []
                ),
                [:],
                .duplicateOption("--browser-handoff")
            ),
            (
                ParsedValues(
                    positional: [],
                    options: ["browserHandoff": [store.fileURL.path]],
                    flags: []
                ),
                [:],
                .exactBridgeSocketRequired
            ),
            (
                ParsedValues(
                    positional: [],
                    options: ["browserHandoff": [store.fileURL.path], "bridge-socket": [socket]],
                    flags: ["no-remote"]
                ),
                [:],
                .localExecutionRefused
            ),
            (valid, ["PEEKABOO_NO_REMOTE": "1"], .localExecutionRefused),
            (
                valid,
                ["PEEKABOO_BRIDGE_SOCKET": "/private/tmp/other.sock"],
                .conflictingBridgeSocket
            ),
        ]
        for (values, environment, expected) in invalidCases {
            #expect(throws: expected) {
                _ = try CommanderCLIBinder.makeRuntimeOptions(
                    from: values,
                    commandType: MCPCommand.Serve.self,
                    environment: environment
                )
            }
        }
    }

    @Test
    @MainActor
    func `unsafe MCP receipt refuses before runtime factory construction`() async throws {
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = directory.appendingPathComponent("handoff.json")
        try Data("{}".utf8).write(to: receipt)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        let expected = BrowserHandoffReceiptStoreError.invalidReceipt("receipt bundle is not internally valid")
        var runtimeConstructed = false

        await #expect(throws: BrowserHandoffCLIInputError.invalidReceipt(expected.localizedDescription)) {
            try await CommanderRuntimeExecutor.resolveAndRun(
                arguments: [
                    "peekaboo", "mcp", "serve",
                    "--browser-handoff", receipt.path,
                    "--bridge-socket", "/private/tmp/peekaboo-handoff.sock",
                ],
                runtimeFactory: .init { _ in
                    runtimeConstructed = true
                    throw StopBeforeRuntimeConstruction()
                }
            )
        }
        #expect(!runtimeConstructed)
    }

    @Test
    @MainActor
    func `valid MCP receipt reaches runtime factory before any server construction`() async throws {
        let fixture = try await Self.canonicalHandoffData()
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BrowserHandoffReceiptStore(fileURL: directory.appendingPathComponent("handoff.json"))
        try store.save(fixture)
        var receivedData: Data?

        await #expect(throws: StopBeforeRuntimeConstruction.self) {
            try await CommanderRuntimeExecutor.resolveAndRun(
                arguments: [
                    "peekaboo", "mcp", "serve",
                    "--browser-handoff", store.fileURL.path,
                    "--bridge-socket", "/private/tmp/peekaboo-handoff.sock",
                ],
                runtimeFactory: .init { options in
                    receivedData = options.browserHandoffReceiptBundleData
                    throw StopBeforeRuntimeConstruction()
                }
            )
        }
        #expect(receivedData == fixture)
    }

    @Test
    @MainActor
    func `handoff server open is scoped fail closed and cleaned up exactly once`() async throws {
        let receiptData = Data("fixture-signed-handoff".utf8)
        let provider = HandoffToolFixtureBrowser()
        let services = Self.services(browser: provider)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: services,
            selectedRemoteSocketPath: "/private/tmp/peekaboo-handoff.sock",
            browserHandoffReceiptBundleData: receiptData
        )

        let context = MCPCommand.Serve.makeToolContext(
            services: services,
            snapshotMutationCoordinator: nil
        )
        let server = try await PeekabooMCPServer(
            toolContext: context,
            browserHandoff: BrowserMCPHandoffGrant(payload: receiptData)
        )
        #expect(provider.openedReceiptData == receiptData)
        #expect(await server.browserClientForTesting() !== provider)
        await server.stopForTesting()
        await server.stopForTesting()
        #expect(provider.sessionCleanupCount == 1)

        let unavailableRuntime = CommandRuntime(
            configuration: runtime.configuration,
            services: PeekabooServices(),
            selectedRemoteSocketPath: "/private/tmp/peekaboo-handoff.sock",
            browserHandoffReceiptBundleData: receiptData
        )
        let unavailableContext = MCPCommand.Serve.makeToolContext(
            services: unavailableRuntime.services,
            snapshotMutationCoordinator: nil
        )
        await #expect(throws: BrowserMCPConnectionError.receiptBindingUnsupported) {
            _ = try await PeekabooMCPServer(
                toolContext: unavailableContext,
                browserHandoff: BrowserMCPHandoffGrant(payload: receiptData)
            )
        }
    }
}

extension BrowserHandoffCLITests {
    @MainActor
    private static func browserCommand(
        action: String,
        handoffValues: [String],
        socketValues: [String],
        flags: Set<String>
    ) throws -> BrowserCommand {
        var options: [String: [String]] = [:]
        if !handoffValues.isEmpty {
            options["handoffFile"] = handoffValues
        }
        if !socketValues.isEmpty {
            options["bridge-socket"] = socketValues
        }
        return try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(positional: [action], options: options, flags: flags)
        )
    }

    private static func privateDirectory() throws -> URL {
        let baseDirectory = try Self.canonicalExistingDirectory(FileManager.default.temporaryDirectory)
        let directory = baseDirectory.appendingPathComponent(
            "peekaboo-browser-handoff-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try Self.createPrivateDirectory(at: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return directory
    }

    private static func canonicalExistingDirectory(_ directory: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard directory.path.withCString({ realpath($0, &buffer) }) != nil else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func createPrivateDirectory(at directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Ambient ACLs or attributes are a failing fixture precondition, never the intended negative case.
        try BrowserHandoffReceiptStore(fileURL: directory.appendingPathComponent("baseline.json")).validateCanSave()
    }

    private static func cleanReceiptStore(_ data: Data, at file: URL) throws -> BrowserHandoffReceiptStore {
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = try BrowserHandoffReceiptStore(fileURL: file)
        _ = try store.load()
        return store
    }

    private static func addExtendedAttribute(to url: URL) throws -> String {
        let privateValue = UUID().uuidString
        let value = Data(privateValue.utf8)
        let result = value.withUnsafeBytes { bytes in
            url.path.withCString { path in
                "dev.peekaboo.browser-handoff-test".withCString { name in
                    setxattr(path, name, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
        return privateValue
    }

    private static func addReadableACL(to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func canonicalHandoffData() async throws -> Data {
        try await BrowserHandoffReceiptFixture.canonicalData()
    }

    @MainActor
    private static func services(browser: any BrowserMCPClientProviding) -> PeekabooServices {
        let defaults = PeekabooServices()
        return PeekabooServices(
            logging: defaults.logging,
            screenCapture: defaults.screenCapture,
            applications: defaults.applications,
            automation: defaults.automation,
            windows: defaults.windows,
            menu: defaults.menu,
            dock: defaults.dock,
            dialogs: defaults.dialogs,
            snapshots: defaults.snapshots,
            files: defaults.files,
            clipboard: defaults.clipboard,
            permissions: defaults.permissions,
            audioInput: defaults.audioInput,
            browser: browser,
            configuration: defaults.configuration,
            screens: defaults.screens
        )
    }
}

@MainActor
private final class HandoffToolFixtureBrowser: BrowserMCPConnectionHandoffProviding,
BrowserMCPScopedSessionOpening, BrowserMCPScopedSessionEnding, @unchecked Sendable {
    private(set) var handoffConnectCount = 0
    private(set) var disconnectResultCount = 0
    private let handoffPayload: Data
    private var handoffData: Data?
    private(set) var openedReceiptData: Data?
    private(set) var sessionCleanupCount = 0
    private weak var cleanupOwner: HandoffToolFixtureBrowser?
    private var sessionEnded = false

    init(
        cleanupOwner: HandoffToolFixtureBrowser? = nil,
        handoffPayload: Data = Data("private-handoff-bytes".utf8)
    ) {
        self.cleanupOwner = cleanupOwner
        self.handoffPayload = handoffPayload
    }

    nonisolated var supportsNativeBrowserConnectionBinding: Bool {
        true
    }

    private static let receipt = BrowserMCPConnectionReceipt(
        channel: .stable,
        browserURL: "http://127.0.0.1:9222/",
        webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-handoff",
        devToolsBrowserID: "browser-handoff",
        browserVersion: "Chrome/151.0",
        protocolVersion: "1.3"
    )

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        Self.connectedStatus
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        Self.connectedStatus
    }

    func connect(channel _: BrowserMCPChannel?, browserURL _: String?) async throws -> BrowserMCPStatus {
        Self.connectedStatus
    }

    func connectWithOutcome(
        channel _: BrowserMCPChannel?,
        browserURL _: String?
    ) async throws -> DesktopActionResult<BrowserMCPStatus> {
        DesktopActionResult(payload: Self.connectedStatus, outcome: .confirmedNoChange())
    }

    func connectWithHandoffOutcome(
        channel _: BrowserMCPChannel?,
        browserURL _: String?
    ) async throws -> DesktopActionResult<BrowserMCPStatus> {
        self.handoffConnectCount += 1
        self.handoffData = self.handoffPayload
        return DesktopActionResult(payload: Self.connectedStatus, outcome: .confirmedNoChange())
    }

    func takeConnectionHandoffReceiptBundleData() -> Data? {
        defer { self.handoffData = nil }
        return self.handoffData
    }

    func openBrowserMCPScopedSession(
        handoff: BrowserMCPHandoffGrant?
    ) async throws -> any BrowserMCPScopedSessionEnding {
        self.openedReceiptData = handoff?.payload
        return HandoffToolFixtureBrowser(cleanupOwner: self)
    }

    func endBrowserMCPScopedSession() async -> Bool {
        guard !self.sessionEnded else { return true }
        self.sessionEnded = true
        self.cleanupOwner?.sessionCleanupCount += 1
        return true
    }

    func disconnect() async {}

    func disconnectWithResult() async throws -> BrowserMCPStatus {
        self.disconnectResultCount += 1
        self.handoffData = nil
        return BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?
    ) async throws -> ToolResponse {
        .error("unexpected")
    }

    private static var connectedStatus: BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: true,
            toolCount: 3,
            detectedBrowsers: [],
            connectionReceipt: self.receipt
        )
    }
}

private struct StopBeforeRuntimeConstruction: Error {}

private enum BrowserHandoffReceiptFixture {
    private static let requestedBrowserURL = "http://127.0.0.1:9222"
    private static let connectionReceipt = PeekabooBridgeBrowserConnectionReceipt(
        channel: "stable",
        browserURL: "http://127.0.0.1:9222/",
        webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-handoff-fixture",
        devToolsBrowserID: "browser-handoff-fixture",
        browserVersion: "Chrome/151.0",
        protocolVersion: "1.3"
    )

    static func canonicalData() async throws -> Data {
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: "/tmp/peekaboo-browser-handoff-fixture-\(UUID().uuidString).sock"
        )
        let archiveDirectory = URL(
            fileURLWithPath: authority.attestation.receiptArchiveDirectory,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: archiveDirectory) }

        let peer = try self.currentPeer()
        let clientInstanceID = UUID()
        let session = try await authority.createSession(
            clientInstanceID: clientInstanceID,
            peer: peer,
            negotiatedCapabilities: .current
        )
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .browserConnect(.init(
            channel: "stable",
            browserURL: self.requestedBrowserURL,
            requestsHandoff: true
        ))))
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .browserStatus(.init(
                isConnected: true,
                toolCount: 10,
                detectedBrowsers: [],
                connectionReceipt: self.connectionReceipt
            )),
            outcome: outcome.projection
        ))
        let sequence = PeekabooBridgeOperationSessionSequence(0)
        let attestedRequest = PeekabooBridgeAttestedOperationRequest(
            requestID: PeekabooBridgeOperationReceiptCoding.deterministicRequestID(
                sessionID: session.sessionID,
                sequence: sequence
            ),
            sessionID: session.sessionID,
            sessionSequence: sequence,
            expectedListenerInstanceID: authority.attestation.listenerInstanceID,
            clientInstanceID: clientInstanceID,
            client: session.client,
            request: request
        )
        guard case let .accepted(claim) = try await authority.claim(attestedRequest, peer: peer) else {
            throw BrowserHandoffReceiptFixtureError.claimRefused
        }
        defer { authority.complete(claim) }

        let now = PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        let payload = try PeekabooBridgeOperationReceiptPayload(
            requestID: claim.requestID,
            sessionID: claim.sessionID,
            sessionSequence: claim.sessionSequence,
            sessionAttestationSHA256: PeekabooBridgeOperationReceiptCoding.sha256(session),
            listenerInstanceID: authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                authority.attestation.publicKey
            ),
            host: authority.attestation.host,
            clientInstanceID: clientInstanceID,
            client: session.client,
            operation: .browserConnect,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(request),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(response),
            target: .browser(self.connectionReceipt),
            outcome: outcome.projection,
            remainingClaimCount: claim.remainingClaimCount,
            startedAtUnixMilliseconds: now,
            completedAtUnixMilliseconds: now
        )
        let receipt = try await authority.signAndArchive(payload, claim: claim)
        let bundle = try PeekabooBridgeOperationReceiptBundle(
            operationAttestation: authority.attestation,
            operationSessionAttestation: session,
            receipt: receipt,
            canonicalListenerAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(
                authority.attestation.unsignedPayload
            ),
            canonicalSessionAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(
                session.unsignedPayload
            ),
            canonicalReceiptPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(receipt.payload),
            canonicalRequest: PeekabooBridgeOperationReceiptCoding.canonicalData(request),
            canonicalResponse: PeekabooBridgeOperationReceiptCoding.canonicalData(response)
        )
        try bundle.validate()
        return try PeekabooBridgeOperationReceiptCoding.canonicalData(bundle)
    }

    private static func currentPeer() throws -> PeekabooBridgePeer {
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(getpid()),
              let codeSignatureHash = PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
                  processIdentifier: getpid()
              )
        else {
            throw BrowserHandoffReceiptFixtureError.processIdentityUnavailable
        }
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let auditIdentity = try PeekabooBridgeSocketIO.peerAuditIdentity(fd: descriptors[0])
        let liveIdentity = PeekabooBridgeLivePeerIdentity(
            auditIdentity: auditIdentity,
            processStartIdentity: processStartIdentity,
            codeSignatureHash: codeSignatureHash
        )
        return PeekabooBridgePeer(
            liveIdentity: liveIdentity,
            bundleIdentifier: "dev.peekaboo.browser-handoff-tests",
            teamIdentifier: nil
        )
    }
}

private enum BrowserHandoffReceiptFixtureError: Error {
    case claimRefused
    case processIdentityUnavailable
}
