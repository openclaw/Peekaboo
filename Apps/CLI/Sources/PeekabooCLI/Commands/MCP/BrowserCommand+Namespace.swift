import CoreFoundation
import Darwin
import Foundation
import PeekabooFoundation
import TachikomaMCP

struct BrowserCLINamespaceBindWindowRequest: Equatable, Sendable {
    let pageID: String
    let processIdentifier: Int32
    let windowID: UInt32
}

enum BrowserCLINamespaceControlAction: String, Sendable {
    case create = "namespace_create"
    case close = "namespace_close"
}

enum BrowserCLINamespaceExecutionMode: Sendable {
    case backgroundOnly
    case foregroundAllowed
}

struct BrowserCLINamespaceHighLevelActionRequest: @unchecked Sendable {
    let action: BrowserAction
    let arguments: [String: Any]
    let executionMode: BrowserCLINamespaceExecutionMode
}

struct BrowserCLINamespaceCreateResult: Sendable {
    /// Complete signed receipt bytes are private state and must never be copied into `response`.
    let namespaceReceiptData: Data
    let response: ToolResponse
}

protocol BrowserCLINamespaceBridgeAdapter: Sendable {
    /// Creates one authenticated Bridge namespace. The caller must persist the returned complete receipt
    /// through ``BrowserCLINamespaceReceiptStore`` before treating creation as durable.
    func createNamespace() async throws -> BrowserCLINamespaceCreateResult

    /// Executes only through an authenticated Bridge 1.38 capability namespace.
    /// The adapter owns wire decoding, receipt signature/principal validation, and listener matching.
    func bindWindow(
        request: BrowserCLINamespaceBindWindowRequest,
        namespaceReceiptData: Data
    ) async throws -> ToolResponse

    /// Executes only one action from the closed Bridge 1.38 high-level action enum.
    /// Raw provider calls and legacy browser transport are not representable through this method.
    func executeAction(
        request: BrowserCLINamespaceHighLevelActionRequest,
        namespaceReceiptData: Data
    ) async throws -> ToolResponse

    /// Closes the exact namespace. A non-error response must mean the host confirmed status `closed`;
    /// the caller removes its receipt file only after that response.
    func closeNamespace(namespaceReceiptData: Data) async throws -> ToolResponse
}

@MainActor
protocol BrowserCLINamespaceBridgeAdapterProviding: AnyObject {
    /// Present only when the selected RemotePeekabooServices was built from a negotiated Bridge 1.38 client.
    var browserCLINamespaceBridgeAdapter: any BrowserCLINamespaceBridgeAdapter { get }
}

/// The Bridge 1.38 integration makes only its negotiated `RemotePeekabooServices` conform to the
/// provider above. This base-scoped lane deliberately has no production fallback; until the wire
/// stack supplies that conformance, valid requests fail closed with `adapterUnavailable`.
enum BrowserCLINamespaceEnvironment {
    #if DEBUG
    @TaskLocal private static var testBridgeAdapterOverride: (any BrowserCLINamespaceBridgeAdapter)?
    #endif

    @MainActor
    static func adapter(for runtime: CommandRuntime) -> (any BrowserCLINamespaceBridgeAdapter)? {
        guard runtime.services.executionHost == .remote,
              runtime.selectedRemoteSocketPath != nil
        else { return nil }
        if let provider = runtime.services as? any BrowserCLINamespaceBridgeAdapterProviding {
            return provider.browserCLINamespaceBridgeAdapter
        }
        #if DEBUG
        return self.testBridgeAdapterOverride
        #else
        return nil
        #endif
    }

    #if DEBUG
    static func withBridgeAdapter<T>(
        _ adapter: any BrowserCLINamespaceBridgeAdapter,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await self.$testBridgeAdapterOverride.withValue(adapter) {
            try await operation()
        }
    }
    #endif
}

enum BrowserCLINamespaceLifecycle {
    static func create(
        adapter: any BrowserCLINamespaceBridgeAdapter,
        store: BrowserCLINamespaceReceiptStore
    ) async throws -> ToolResponse {
        try store.validateCanSave()
        let creation = try await adapter.createNamespace()
        if creation.response.isError {
            do {
                try await self.rollbackCreatedNamespace(
                    adapter: adapter,
                    receipt: creation.namespaceReceiptData
                )
            } catch {
                throw BrowserCLINamespacePostDispatchError.creationRollbackFailed(error.localizedDescription)
            }
            return creation.response
        }
        do {
            try store.save(creation.namespaceReceiptData)
        } catch {
            let persistenceError = error
            do {
                try await self.rollbackCreatedNamespace(
                    adapter: adapter,
                    receipt: creation.namespaceReceiptData
                )
            } catch {
                throw BrowserCLINamespacePostDispatchError.creationRollbackFailed(error.localizedDescription)
            }
            throw BrowserCLINamespacePostDispatchError.creationRolledBack(
                persistenceError.localizedDescription
            )
        }
        return creation.response
    }

    static func close(
        adapter: any BrowserCLINamespaceBridgeAdapter,
        store: BrowserCLINamespaceReceiptStore
    ) async throws -> ToolResponse {
        let receipt = try store.load()
        let response = try await adapter.closeNamespace(namespaceReceiptData: receipt)
        if !response.isError {
            do {
                try store.remove(expectedReceipt: receipt)
            } catch {
                throw BrowserCLINamespacePostDispatchError.closedReceiptCleanupFailed(
                    error.localizedDescription
                )
            }
        }
        return response
    }

    private static func rollbackCreatedNamespace(
        adapter: any BrowserCLINamespaceBridgeAdapter,
        receipt: Data
    ) async throws {
        let rollback = try await adapter.closeNamespace(namespaceReceiptData: receipt)
        guard !rollback.isError else {
            throw BrowserCLINamespaceReceiptStoreError.writeFailed(
                "created namespace could not be persisted or closed and will expire"
            )
        }
    }
}

enum BrowserCLINamespacePostDispatchError: LocalizedError, ResultEnvelopeError, Equatable {
    case creationRolledBack(String)
    case creationRollbackFailed(String)
    case closedReceiptCleanupFailed(String)

    nonisolated var errorDescription: String? {
        switch self {
        case let .creationRolledBack(cause):
            "The Bridge namespace was created and closed, but its receipt could not be persisted: \(cause)"
        case let .creationRollbackFailed(cause):
            "The Bridge namespace was created but could not be persisted or closed; it will expire: \(cause)"
        case let .closedReceiptCleanupFailed(cause):
            "The Bridge namespace was closed, but its local receipt could not be removed: \(cause)"
        }
    }

    nonisolated var envelopeCode: ErrorCode? {
        .INTERACTION_FAILED
    }

    nonisolated var envelopeEffect: ActionEffect? {
        .partial
    }

    nonisolated var envelopeHint: String? {
        switch self {
        case .creationRolledBack:
            "The rollback was confirmed; fix the private receipt path before creating a new namespace."
        case .creationRollbackFailed:
            "Do not retry automatically. Let the unpersisted namespace expire before creating another one."
        case .closedReceiptCleanupFailed:
            "Do not overwrite the receipt. Remove it only after confirming it names the namespace just closed."
        }
    }

    nonisolated var envelopeRetrySafe: Bool? {
        switch self {
        case .creationRolledBack: true
        case .creationRollbackFailed, .closedReceiptCleanupFailed: false
        }
    }

    nonisolated var envelopeMutationDispatched: Bool? {
        true
    }
}

enum BrowserCLINamespaceCommandError: LocalizedError, ResultEnvelopeError, Equatable {
    case missingSelectors
    case invalidPageReference
    case invalidProcessIdentifier
    case invalidWindowID
    case missingNamespaceFile
    case invalidNamespaceFile
    case unsupportedNamespaceAction(String)
    case unsupportedArguments([String])
    case localExecutionRefused
    case bridgeHostRequired(String)
    case adapterUnavailable

    nonisolated var errorDescription: String? {
        switch self {
        case .missingSelectors:
            "browser bind-window requires --page-id, --pid, and --window-id."
        case .invalidPageReference:
            "browser bind-window --page-id must be an opaque bp1 capability from this Bridge namespace."
        case .invalidProcessIdentifier:
            "browser bind-window --pid must be a positive Int32."
        case .invalidWindowID:
            "browser bind-window --window-id must be a positive UInt32."
        case .missingNamespaceFile:
            "Browser namespace actions require an explicit --namespace-file."
        case .invalidNamespaceFile:
            "--namespace-file must resolve to an absolute browser namespace receipt path."
        case let .unsupportedNamespaceAction(action):
            "Browser action '\(action)' is not in the closed Bridge 1.38 namespace action set."
        case let .unsupportedArguments(arguments):
            "browser bind-window does not accept \(arguments.joined(separator: ", "))."
        case .localExecutionRefused:
            "browser bind-window requires an authenticated Bridge 1.38 namespace; --no-remote is not supported."
        case let .bridgeHostRequired(message):
            message
        case .adapterUnavailable:
            "The selected Bridge host did not provide its negotiated 1.38 browser namespace adapter."
        }
    }

    nonisolated var envelopeCode: ErrorCode? {
        switch self {
        case .bridgeHostRequired, .adapterUnavailable: .BRIDGE_UNAVAILABLE
        default: .VALIDATION_ERROR
        }
    }

    nonisolated var envelopeEffect: ActionEffect? {
        nil
    }

    nonisolated var envelopeRetrySafe: Bool? {
        true
    }

    nonisolated var envelopeMutationDispatched: Bool? {
        false
    }

    nonisolated var envelopeHint: String? {
        switch self {
        case .missingSelectors, .invalidPageReference, .invalidProcessIdentifier, .invalidWindowID:
            "Pass exactly the opaque page capability, Chrome PID, and native WindowServer ID returned for " +
                "this namespace."
        case .missingNamespaceFile, .invalidNamespaceFile:
            "Pass the exact owner-private receipt file created for this authenticated Bridge namespace."
        case .unsupportedNamespaceAction:
            "Use one documented high-level browser action; raw call/provider tools are intentionally unavailable."
        case .unsupportedArguments:
            "Remove unrelated browser options; bind-window accepts only --namespace-file and its three selectors."
        case .localExecutionRefused:
            "Remove --no-remote and use the authenticated Bridge that issued the stored namespace receipt."
        case .bridgeHostRequired:
            "Select the exact authenticated Bridge that issued the receipt; local and legacy hosts are refused."
        case .adapterUnavailable:
            "Upgrade the selected Bridge host and retry only after it negotiates browser capability namespaces."
        }
    }
}

extension BrowserCommand {
    var usesBrowserCapabilityNamespace: Bool {
        self.normalizedAction == BrowserProcessLocalAction.bindWindow ||
            BrowserCLINamespaceControlAction(rawValue: self.normalizedAction) != nil ||
            self.namespaceFile != nil
    }

    func validateBrowserCapabilityNamespaceActionBeforeRuntime(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try self.requireRemoteNamespaceRouting(environment: environment)
        let store = try self.namespaceReceiptStore()
        if let control = BrowserCLINamespaceControlAction(rawValue: self.normalizedAction) {
            let unsupported = self.namespaceUnsupportedArguments(allowsBindSelectors: false)
            guard unsupported.isEmpty else {
                throw BrowserCLINamespaceCommandError.unsupportedArguments(unsupported)
            }
            switch control {
            case .create:
                try store.validateCanSaveBeforeRuntime()
            case .close:
                _ = try store.load()
            }
            return
        }
        if self.normalizedAction == BrowserProcessLocalAction.bindWindow {
            _ = try self.namespaceBindWindowRequest(environment: environment)
            _ = try store.load()
            return
        }
        _ = try self.namespaceHighLevelActionRequest()
        _ = try store.load()
    }

    mutating func runBrowserCapabilityNamespaceAction() async throws {
        let store = try self.namespaceReceiptStore()
        let adapter = try self.namespaceAdapter()
        if let control = BrowserCLINamespaceControlAction(rawValue: self.normalizedAction) {
            switch control {
            case .create:
                try await self.runNamespaceCreate(adapter: adapter, store: store)
            case .close:
                try await self.runNamespaceClose(adapter: adapter, store: store)
            }
            return
        }
        if self.normalizedAction == BrowserProcessLocalAction.bindWindow {
            let request = try self.namespaceBindWindowRequest()
            let receipt = try store.load()
            let response = try await adapter.bindWindow(
                request: request,
                namespaceReceiptData: receipt
            )
            try self.outputNamespaceResponse(response)
            return
        }
        let request = try self.namespaceHighLevelActionRequest()
        let receipt = try store.load()
        if Self.actionMayMutate(request.action.rawValue) {
            self.resolvedRuntime.beginInteractionMutation()
        }
        let response = try await adapter.executeAction(
            request: request,
            namespaceReceiptData: receipt
        )
        try self.outputNamespaceResponse(response)
    }

    func namespaceBindWindowRequest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> BrowserCLINamespaceBindWindowRequest {
        let unsupported = self.namespaceUnsupportedArguments(allowsBindSelectors: true)
        guard unsupported.isEmpty else {
            throw BrowserCLINamespaceCommandError.unsupportedArguments(unsupported)
        }
        try self.requireRemoteNamespaceRouting(environment: environment)
        _ = try self.namespaceReceiptStore()
        guard let pageReference = self.pageId,
              let processIdentifier = self.pid,
              let windowID = self.windowId
        else {
            throw BrowserCLINamespaceCommandError.missingSelectors
        }
        guard Self.isOpaqueBrowserPageReference(pageReference) else {
            throw BrowserCLINamespaceCommandError.invalidPageReference
        }
        guard let exactProcessIdentifier = Int32(exactly: processIdentifier), exactProcessIdentifier > 0 else {
            throw BrowserCLINamespaceCommandError.invalidProcessIdentifier
        }
        guard let exactWindowID = UInt32(exactly: windowID), exactWindowID > 0 else {
            throw BrowserCLINamespaceCommandError.invalidWindowID
        }
        return BrowserCLINamespaceBindWindowRequest(
            pageID: pageReference,
            processIdentifier: exactProcessIdentifier,
            windowID: exactWindowID
        )
    }

    func namespaceHighLevelActionRequest() throws -> BrowserCLINamespaceHighLevelActionRequest {
        guard let action = BrowserAction(rawValue: self.normalizedAction),
              action.rawValue != BrowserAction.call.rawValue
        else {
            throw BrowserCLINamespaceCommandError.unsupportedNamespaceAction(self.action)
        }
        var arguments = try self.arguments()
        arguments.removeValue(forKey: "action")
        return BrowserCLINamespaceHighLevelActionRequest(
            action: action,
            arguments: arguments,
            executionMode: self.foreground ? .foregroundAllowed : .backgroundOnly
        )
    }

    private func namespaceAdapter() throws -> any BrowserCLINamespaceBridgeAdapter {
        guard self.runtimeOptions.requiresBrowserCapabilityNamespace,
              self.services.executionHost == .remote,
              self.resolvedRuntime.selectedRemoteSocketPath != nil
        else {
            throw BrowserCLINamespaceCommandError.bridgeHostRequired(
                self.resolvedRuntime.requiredHostFailure ??
                    "browser bind-window did not select an authenticated remote Bridge 1.38 namespace host."
            )
        }
        guard let adapter = BrowserCLINamespaceEnvironment.adapter(for: self.resolvedRuntime) else {
            throw BrowserCLINamespaceCommandError.adapterUnavailable
        }
        return adapter
    }

    private mutating func runNamespaceCreate(
        adapter: any BrowserCLINamespaceBridgeAdapter,
        store: BrowserCLINamespaceReceiptStore
    ) async throws {
        let response = try await BrowserCLINamespaceLifecycle.create(adapter: adapter, store: store)
        try self.outputNamespaceResponse(response)
    }

    private mutating func runNamespaceClose(
        adapter: any BrowserCLINamespaceBridgeAdapter,
        store: BrowserCLINamespaceReceiptStore
    ) async throws {
        let response = try await BrowserCLINamespaceLifecycle.close(adapter: adapter, store: store)
        try self.outputNamespaceResponse(response)
    }

    private func outputNamespaceResponse(_ response: ToolResponse) throws {
        try MCPToolCommandOutput.output(
            tool: "browser",
            response: response,
            jsonOutput: self.jsonOutput,
            logger: self.outputLogger
        )
    }

    private func requireRemoteNamespaceRouting(environment: [String: String]) throws {
        guard !self.runtimeOptions.remoteIsolationRequested, environment["PEEKABOO_NO_REMOTE"] == nil else {
            throw BrowserCLINamespaceCommandError.localExecutionRefused
        }
    }

    func namespaceReceiptStore() throws -> BrowserCLINamespaceReceiptStore {
        guard let namespaceFile = self.namespaceFile?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !namespaceFile.isEmpty
        else {
            throw BrowserCLINamespaceCommandError.missingNamespaceFile
        }
        do {
            return try BrowserCLINamespaceReceiptStore(resolvingPath: namespaceFile)
        } catch {
            throw BrowserCLINamespaceCommandError.invalidNamespaceFile
        }
    }

    private func namespaceUnsupportedArguments(allowsBindSelectors: Bool) -> [String] {
        var arguments: [String] = []
        func append(_ present: Bool, _ name: String) {
            if present {
                arguments.append(name)
            }
        }

        append(self.channel != nil, "--channel")
        append(self.browserUrl != nil, "--browser-url")
        append(!allowsBindSelectors && self.pageId != nil, "--page-id")
        append(!allowsBindSelectors && self.pid != nil, "--pid")
        append(!allowsBindSelectors && self.windowId != nil, "--window-id")
        append(self.url != nil, "--url")
        append(self.navigationType != nil, "--navigation-type")
        append(self.uid != nil, "--uid")
        append(self.toUid != nil, "--to-uid")
        append(self.text != nil, "--text")
        append(self.value != nil, "--value")
        append(self.key != nil, "--key")
        append(self.submitKey != nil, "--submit-key")
        append(self.dialogAction != nil, "--dialog-action")
        append(self.includeSnapshot, "--include-snapshot")
        append(self.double, "--double")
        append(self.bringToFront, "--bring-to-front")
        append(self.noBringToFront, "--no-bring-to-front")
        append(self.background, "--background")
        append(self.foreground, "--foreground")
        append(self.timeout != nil, "--timeout")
        append(self.pageSize != nil, "--page-size")
        append(self.pageIndex != nil, "--page-index")
        append(!self.types.isEmpty, "--type")
        append(!self.resourceTypes.isEmpty, "--resource-type")
        append(self.includePreserved, "--include-preserved")
        append(self.messageId != nil, "--message-id")
        append(self.requestId != nil, "--request-id")
        append(self.requestFilePath != nil, "--request-file-path")
        append(self.responseFilePath != nil, "--response-file-path")
        append(self.path != nil, "--path")
        append(self.format != nil, "--format")
        append(self.quality != nil, "--quality")
        append(self.fullPage, "--full-page")
        append(self.traceAction != nil, "--trace-action")
        append(self.noReload, "--no-reload")
        append(self.noAutoStop, "--no-auto-stop")
        append(self.insightSetId != nil, "--insight-set-id")
        append(self.insightName != nil, "--insight-name")
        append(self.mcpTool != nil, "--mcp-tool")
        append(self.mcpArgsJson != nil, "--mcp-args-json")
        append(self.runtimeOptions.inputStrategy != nil, "--input-strategy")
        append(self.runtimeOptions.captureEnginePreference != nil, "--capture-engine")
        return arguments.sorted()
    }

    static func isOpaqueBrowserPageReference(_ value: String) -> Bool {
        self.isOpaqueBrowserReference(value, prefix: "bp1")
    }

    static func isOpaqueBrowserElementReference(_ value: String) -> Bool {
        self.isOpaqueBrowserReference(value, prefix: "be1")
    }

    private static func isOpaqueBrowserReference(_ value: String, prefix: String) -> Bool {
        let expectedPrefix = prefix + "_"
        guard value.hasPrefix(expectedPrefix) else { return false }
        let token = value.dropFirst(expectedPrefix.count)
        return token.count == 32 && token.allSatisfy { character in
            guard let ascii = character.asciiValue else { return false }
            return (48...57).contains(ascii) || (97...102).contains(ascii)
        }
    }
}

struct BrowserCLINamespaceReceiptStore: Sendable {
    static let maximumReceiptBytes: off_t = 16 * 1024

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    init(resolvingPath path: String) throws {
        guard !path.utf8.contains(0) else {
            throw BrowserCLINamespaceReceiptStoreError.unsafeState("state path is invalid")
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw BrowserCLINamespaceReceiptStoreError.unsafeState("state path must be absolute")
        }
        let resolved = URL(fileURLWithPath: expanded, isDirectory: false).standardizedFileURL
        guard !resolved.lastPathComponent.isEmpty,
              resolved.lastPathComponent != ".",
              resolved.lastPathComponent != ".."
        else {
            throw BrowserCLINamespaceReceiptStoreError.unsafeState("state path is invalid")
        }
        self.fileURL = resolved
    }

    func load() throws -> Data {
        let directory = try self.openPrivateDirectory(createIfMissing: false)
        defer { Darwin.close(directory) }
        let descriptor = self.fileURL.lastPathComponent.withCString { name in
            openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw BrowserCLINamespaceReceiptStoreError.missing
            }
            throw BrowserCLINamespaceReceiptStoreError.unsafeState(Self.openFailureReason(errno))
        }
        defer { Darwin.close(descriptor) }

        let before = try Self.validatedFileMetadata(descriptor)
        let data = try Self.readExactly(descriptor, expectedSize: Int(before.st_size))
        var after = stat()
        guard fstat(descriptor, &after) == 0, Self.sameFile(before, after), Int64(data.count) == before.st_size else {
            throw BrowserCLINamespaceReceiptStoreError.unsafeState("state changed while it was being read")
        }
        try Self.validateCanonicalReceipt(data)
        return data
    }

    /// Establishes the private parent directory and proves the exact destination is still unused.
    /// `save` repeats this check atomically, so namespace creation can preflight before remote admission.
    func validateCanSave() throws {
        let directory = try self.openPrivateDirectory(createIfMissing: true)
        defer { Darwin.close(directory) }
        try self.requireDestinationAbsent(in: directory)
    }

    /// Request-only preflight used before host discovery. A missing parent is allowed and is created only
    /// during command execution; an existing parent and destination are inspected without mutation.
    func validateCanSaveBeforeRuntime() throws {
        do {
            let directory = try self.openPrivateDirectory(createIfMissing: false)
            defer { Darwin.close(directory) }
            try self.requireDestinationAbsent(in: directory)
        } catch BrowserCLINamespaceReceiptStoreError.missing {
            return
        }
    }

    func save(_ canonicalReceipt: Data) throws {
        try Self.validateCanonicalReceipt(canonicalReceipt)
        let directory = try self.openPrivateDirectory(createIfMissing: true)
        defer { Darwin.close(directory) }
        try self.requireDestinationAbsent(in: directory)

        let destinationName = self.fileURL.lastPathComponent
        let temporaryName = ".\(destinationName).\(UUID().uuidString.lowercased()).tmp"
        let descriptor = temporaryName.withCString { name in
            openat(
                directory,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw BrowserCLINamespaceReceiptStoreError.writeFailed("temporary state could not be created")
        }
        var temporaryStillExists = true
        defer {
            Darwin.close(descriptor)
            if temporaryStillExists {
                _ = temporaryName.withCString { unlinkat(directory, $0, 0) }
            }
        }

        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw BrowserCLINamespaceReceiptStoreError.writeFailed("temporary state permissions could not be set")
        }
        _ = try Self.validatedFileMetadata(descriptor, expectedSize: 0)
        try Self.writeExactly(canonicalReceipt, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw BrowserCLINamespaceReceiptStoreError.writeFailed("temporary state could not be synchronized")
        }
        _ = try Self.validatedFileMetadata(descriptor, expectedSize: off_t(canonicalReceipt.count))

        let renameResult = temporaryName.withCString { source in
            destinationName.withCString { destination in
                renameatx_np(directory, source, directory, destination, UInt32(RENAME_EXCL))
            }
        }
        guard renameResult == 0 else {
            if errno == EEXIST {
                throw BrowserCLINamespaceReceiptStoreError.alreadyExists
            }
            throw BrowserCLINamespaceReceiptStoreError.writeFailed("state could not be published atomically")
        }
        // `renameatx_np(RENAME_EXCL)` is the commit point. The already-fsynced, validated inode is now the
        // exact destination, and no later diagnostic may turn this into a persistence failure that rolls
        // back the remote namespace while leaving its receipt published.
        temporaryStillExists = false
        _ = fsync(directory)
    }

    func remove(expectedReceipt: Data) throws {
        try Self.validateCanonicalReceipt(expectedReceipt)
        let directory = try self.openPrivateDirectory(createIfMissing: false)
        defer { Darwin.close(directory) }
        let name = self.fileURL.lastPathComponent
        let descriptor = name.withCString { value in
            openat(directory, value, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return
            }
            throw BrowserCLINamespaceReceiptStoreError.unsafeState(Self.openFailureReason(errno))
        }
        defer { Darwin.close(descriptor) }
        let opened = try Self.validatedFileMetadata(descriptor)
        let openedData = try Self.readExactly(descriptor, expectedSize: Int(opened.st_size))
        var afterRead = stat()
        guard fstat(descriptor, &afterRead) == 0,
              Self.sameFile(opened, afterRead),
              openedData == expectedReceipt
        else {
            throw BrowserCLINamespaceReceiptStoreError.receiptMismatch
        }
        try Self.validateCanonicalReceipt(openedData)
        let quarantineName = ".\(name).\(UUID().uuidString.lowercased()).closing"
        let renameResult = name.withCString { source in
            quarantineName.withCString { destination in
                renameatx_np(directory, source, directory, destination, UInt32(RENAME_EXCL))
            }
        }
        guard renameResult == 0 else {
            throw BrowserCLINamespaceReceiptStoreError.writeFailed("state could not be removed")
        }
        let quarantineDescriptor = quarantineName.withCString { value in
            openat(directory, value, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard quarantineDescriptor >= 0 else {
            throw BrowserCLINamespaceReceiptStoreError.writeFailed("quarantined state could not be reopened")
        }
        defer { Darwin.close(quarantineDescriptor) }
        let quarantined = try Self.validatedFileMetadata(quarantineDescriptor)
        guard opened.st_dev == quarantined.st_dev, opened.st_ino == quarantined.st_ino else {
            _ = quarantineName.withCString { source in
                name.withCString { destination in
                    renameatx_np(directory, source, directory, destination, UInt32(RENAME_EXCL))
                }
            }
            throw BrowserCLINamespaceReceiptStoreError.writeFailed(
                "state changed before it could be removed safely"
            )
        }
        guard quarantineName.withCString({ unlinkat(directory, $0, 0) }) == 0 else {
            throw BrowserCLINamespaceReceiptStoreError.writeFailed("quarantined state could not be removed")
        }
        _ = fsync(directory)
    }

    static func validateCanonicalReceipt(_ data: Data) throws {
        guard !data.isEmpty, data.count <= Int(self.maximumReceiptBytes) else {
            throw BrowserCLINamespaceReceiptStoreError.invalidState(
                "receipt must be nonempty and at most \(self.maximumReceiptBytes) bytes"
            )
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw BrowserCLINamespaceReceiptStoreError.invalidState("receipt is not valid JSON")
        }
        guard let receipt = object as? [String: Any], Set(receipt.keys) == ["payload", "signature"],
              let payload = receipt["payload"] as? [String: Any],
              Set(payload.keys) == [
                  "schemaVersion",
                  "namespaceID",
                  "listenerInstanceID",
                  "listenerPublicKeySHA256",
                  "registryGenerationID",
                  "principal",
                  "issuedAtUnixMilliseconds",
                  "expiresAtUnixMilliseconds",
              ],
              let principal = payload["principal"] as? [String: Any],
              Set(principal.keys) == [
                  "effectiveUserIdentifier",
                  "teamIdentifier",
                  "bundleIdentifier",
                  "codeSignatureHash",
              ]
        else {
            throw BrowserCLINamespaceReceiptStoreError.invalidState("receipt schema is not exact")
        }
        guard Self.exactInteger(payload["schemaVersion"]) == 1,
              Self.validVersion4UUID(payload["namespaceID"]),
              Self.validUUID(payload["listenerInstanceID"]),
              Self.validHexDigest(payload["listenerPublicKeySHA256"]),
              Self.validVersion4UUID(payload["registryGenerationID"]),
              let issued = Self.exactInteger(payload["issuedAtUnixMilliseconds"]), issued > 0,
              let expires = Self.exactInteger(payload["expiresAtUnixMilliseconds"]), expires > issued,
              let effectiveUserIdentifier = Self.exactInteger(principal["effectiveUserIdentifier"]),
              UInt32(exactly: effectiveUserIdentifier) != nil,
              effectiveUserIdentifier == Int64(geteuid()),
              Self.validSigningIdentifier(principal["teamIdentifier"], maximumUTF8Bytes: 128),
              Self.validSigningIdentifier(principal["bundleIdentifier"], maximumUTF8Bytes: 512),
              Self.validHex(principal["codeSignatureHash"], count: 40),
              let signature = receipt["signature"] as? String,
              let signatureData = Data(base64Encoded: signature),
              signatureData.count == 64,
              signatureData.base64EncodedString() == signature
        else {
            throw BrowserCLINamespaceReceiptStoreError.invalidState("receipt fields are not canonical")
        }
        guard let canonical = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ),
            canonical == data
        else {
            throw BrowserCLINamespaceReceiptStoreError.invalidState("receipt JSON is not canonical")
        }
    }

    private func openPrivateDirectory(createIfMissing: Bool) throws -> Int32 {
        let directoryURL = self.fileURL.deletingLastPathComponent().standardizedFileURL
        guard !self.fileURL.lastPathComponent.isEmpty,
              self.fileURL.lastPathComponent != ".",
              self.fileURL.lastPathComponent != ".."
        else {
            throw BrowserCLINamespaceReceiptStoreError.unsafeState("state path is invalid")
        }
        var info = stat()
        if lstat(directoryURL.path, &info) != 0 {
            guard createIfMissing, errno == ENOENT,
                  mkdir(directoryURL.path, S_IRWXU) == 0
            else {
                if errno == ENOENT {
                    throw BrowserCLINamespaceReceiptStoreError.missing
                }
                throw BrowserCLINamespaceReceiptStoreError.unsafeState("state directory is unavailable")
            }
        }
        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw BrowserCLINamespaceReceiptStoreError.unsafeState("state directory cannot be opened securely")
        }
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o700
        else {
            Darwin.close(descriptor)
            throw BrowserCLINamespaceReceiptStoreError.unsafeState(
                "state directory must be owned by the current user with mode 0700"
            )
        }
        do {
            try Self.requireNoExtendedACL(descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private func requireDestinationAbsent(in directory: Int32) throws {
        let descriptor = self.fileURL.lastPathComponent.withCString { name in
            openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0 {
            guard errno == ENOENT else {
                throw BrowserCLINamespaceReceiptStoreError.unsafeState(Self.openFailureReason(errno))
            }
            return
        }
        defer { Darwin.close(descriptor) }
        _ = try Self.validatedFileMetadata(descriptor)
        throw BrowserCLINamespaceReceiptStoreError.alreadyExists
    }

    private static func validatedFileMetadata(_ descriptor: Int32, expectedSize: off_t? = nil) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= self.maximumReceiptBytes,
              expectedSize.map({ info.st_size == $0 }) ?? (info.st_size > 0)
        else {
            throw BrowserCLINamespaceReceiptStoreError.unsafeState(
                "state must be one owner-only regular file with mode 0600 and a bounded size"
            )
        }
        try self.requireNoExtendedACL(descriptor)
        return info
    }

    private static func requireNoExtendedACL(_ descriptor: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return
            }
            throw BrowserCLINamespaceReceiptStoreError.unsafeState(
                "state access controls could not be inspected"
            )
        }
        acl_free(UnsafeMutableRawPointer(acl))
        throw BrowserCLINamespaceReceiptStoreError.unsafeState(
            "state must not contain extended access-control entries"
        )
    }

    private static func readExactly(_ descriptor: Int32, expectedSize: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: min(expectedSize, 4096))
        while data.count < expectedSize {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, expectedSize - data.count))
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == -1, errno == EINTR {
                continue
            } else {
                throw BrowserCLINamespaceReceiptStoreError.unsafeState("state changed while it was being read")
            }
        }
        var trailingByte: UInt8 = 0
        while true {
            let count = withUnsafeMutablePointer(to: &trailingByte) { Darwin.read(descriptor, $0, 1) }
            if count == 0 {
                return data
            }
            if count == -1, errno == EINTR {
                continue
            }
            throw BrowserCLINamespaceReceiptStoreError.unsafeState("state changed while it was being read")
        }
    }

    private static func writeExactly(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count == -1, errno == EINTR {
                    continue
                } else {
                    throw BrowserCLINamespaceReceiptStoreError.writeFailed("temporary state could not be written")
                }
            }
        }
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_uid == rhs.st_uid &&
            lhs.st_mode == rhs.st_mode &&
            lhs.st_nlink == rhs.st_nlink &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func exactInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int64(exactly: number.doubleValue),
              NSNumber(value: integer) == number
        else { return nil }
        return integer
    }

    private static func validUUID(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return UUID(uuidString: value) != nil && UUID(uuidString: value)?.uuidString == value
    }

    private static func validVersion4UUID(_ value: Any?) -> Bool {
        guard let value = value as? String,
              let uuid = UUID(uuidString: value),
              uuid.uuidString == value
        else { return false }
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        return bytes[6] >> 4 == 4 && bytes[8] >> 6 == 2 && bytes.contains { $0 != 0 }
    }

    private static func validHexDigest(_ value: Any?) -> Bool {
        self.validHex(value, count: 64)
    }

    private static func validHex(_ value: Any?, count: Int) -> Bool {
        guard let value = value as? String, value.count == count else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validSigningIdentifier(_ value: Any?, maximumUTF8Bytes: Int) -> Bool {
        guard let value = value as? String else { return false }
        let characters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return (1...maximumUTF8Bytes).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            characters.contains($0)
        }
    }

    private static func openFailureReason(_ errorNumber: Int32) -> String {
        switch errorNumber {
        case ELOOP: "symbolic links are not accepted"
        case ENOENT: "state does not exist"
        default: "state cannot be opened securely"
        }
    }
}

enum BrowserCLINamespaceReceiptStoreError: LocalizedError, ResultEnvelopeError, Equatable {
    case missing
    case alreadyExists
    case unsafeState(String)
    case invalidState(String)
    case receiptMismatch
    case writeFailed(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .missing:
            "No durable browser capability namespace receipt is stored."
        case .alreadyExists:
            "A durable browser capability namespace receipt already exists at that path."
        case let .unsafeState(reason):
            "Browser capability namespace state is unsafe: \(reason)."
        case let .invalidState(reason):
            "Browser capability namespace state is invalid: \(reason)."
        case .receiptMismatch:
            "Browser capability namespace state no longer matches the namespace that was closed."
        case let .writeFailed(reason):
            "Browser capability namespace state could not be updated: \(reason)."
        }
    }

    nonisolated var envelopeCode: ErrorCode? {
        switch self {
        case .missing, .unsafeState, .writeFailed: .FILE_IO_ERROR
        case .alreadyExists, .invalidState, .receiptMismatch: .VALIDATION_ERROR
        }
    }

    nonisolated var envelopeEffect: ActionEffect? {
        nil
    }

    nonisolated var envelopeHint: String? {
        switch self {
        case .missing:
            "Create a fresh authenticated Bridge 1.38 browser namespace before retrying."
        case .alreadyExists:
            "Close the existing Bridge namespace and remove its validated receipt before creating another one."
        case .unsafeState, .invalidState:
            "Remove the state only after closing its Bridge namespace, then create a fresh namespace."
        case .receiptMismatch:
            "Keep the newer receipt; do not remove or overwrite a namespace created by another invocation."
        case .writeFailed:
            "Keep the existing namespace state and retry after checking the private state directory."
        }
    }

    nonisolated var envelopeRetrySafe: Bool? {
        true
    }

    nonisolated var envelopeMutationDispatched: Bool? {
        false
    }
}
