import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserMCPHandoffSessionTests {
    @Test
    func `root handoff closes source before exact destination setup and mints fresh authority`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let staleCapabilities = try #require(
            fixture.root.authenticatedSession(named: "mcp:claim-a")?.browserCapabilitySession)

        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:claim-a",
            authorization: fixture.authorization)

        #expect(fixture.detection.calls == 0)
        #expect(await fixture.events.values == [
            "root.remove",
            "destination.add",
            "destination.execute:list_pages",
        ])
        let config = try #require(destinationProvider.addedConfigs.only)
        #expect(config.args.contains("--wsEndpoint=\(Self.webSocketURL)"))
        #expect(!config.args.contains(where: { $0.contains("9999") }))
        #expect(!config.args.contains("--auto-connect"))
        #expect(!config.args.contains("--isolated"))
        #expect(destination.browserCapabilitySession !== staleCapabilities)
        await #expect(throws: BrowserToolCapabilityError.sessionEnded) {
            try await staleCapabilities.withExclusiveOperation { true }
        }

        let status = await destination.status(channel: nil)
        #expect(status.isConnected)
        #expect(status.connectionReceipt == fixture.sourceBinding.connectionReceipt)
        #expect(status.providerSessionEpoch != fixture.sourceBinding.providerSessionEpoch)
        #expect(await destination.endAuthenticatedBrowserSession())
    }

    @Test
    func `forged exact receipt refuses before validation teardown or provider setup`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let receipt = fixture.sourceBinding.connectionReceipt
        let forged = BrowserMCPConnectionReceipt(
            channel: receipt.channel,
            processIdentifier: receipt.processIdentifier,
            processStartIdentity: receipt.processStartIdentity,
            bundleIdentifier: receipt.bundleIdentifier,
            browserURL: receipt.browserURL,
            webSocketDebuggerURL: receipt.webSocketDebuggerURL,
            devToolsBrowserID: receipt.devToolsBrowserID,
            browserVersion: "Chrome/forged",
            protocolVersion: receipt.protocolVersion)

        do {
            _ = try await fixture.root.authorizeConnectionHandoff(connectionReceipt: forged)
            Issue.record("Expected a forged receipt to be refused")
        } catch let error as BrowserMCPConnectionError {
            #expect(error == .expectedConnectionReceiptMismatch)
        }
        #expect(await fixture.endpointResolver.calls == 0)
        #expect(await fixture.events.values.isEmpty)
        #expect(fixture.rootProvider.removeCount == 0)
        #expect(destinationProvider.addedConfigs.isEmpty)
        await fixture.root.disconnect()
    }

    @Test
    func `stale authorization cannot drain a reconnected same target provider generation`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        await fixture.root.disconnect()
        let reconnected = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        #expect(reconnected.connectionReceipt == fixture.authorization.connectionReceipt)
        #expect(reconnected.providerSessionEpoch != fixture.sourceBinding.providerSessionEpoch)
        await fixture.events.reset()
        await fixture.endpointResolver.reset()

        do {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:stale-generation",
                authorization: fixture.authorization)
            Issue.record("Expected stale source generation authorization to be refused")
        } catch let error as BrowserMCPConnectionError {
            #expect(error == .expectedProviderSessionEpochMismatch)
        }
        #expect(await fixture.endpointResolver.calls == 0)
        #expect(await fixture.events.values.isEmpty)
        #expect(destinationProvider.addedConfigs.isEmpty)
        await fixture.root.disconnect()
        await fixture.root.endAuthenticatedSession(named: "mcp:stale-generation")
    }

    @Test
    func `nonpristine destination refuses before source validation or teardown`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.configured = true
        destinationProvider.connected = true
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:occupied",
                authorization: fixture.authorization)
        }

        #expect(await fixture.endpointResolver.calls == 0)
        #expect(fixture.rootProvider.removeCount == 0)
        #expect(destinationProvider.addedConfigs.isEmpty)
        await fixture.root.disconnect()
        await fixture.root.endAuthenticatedSession(named: "mcp:occupied")
    }

    @Test
    func `concurrent copied claim stays locked while root teardown is in flight`() async throws {
        let teardownBarrier = HandoffBarrier()
        let rootProvider = HandoffProviderSpy(label: "root")
        rootProvider.removeBarrier = teardownBarrier
        let firstProvider = HandoffProviderSpy(label: "first")
        let copiedProvider = HandoffProviderSpy(label: "copied")
        let fixture = try await Self.fixture(
            rootProvider: rootProvider,
            destinationProviders: [firstProvider, copiedProvider])

        let first = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:first",
                authorization: fixture.authorization)
        }
        await teardownBarrier.waitUntilBlocked()

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:copied",
                authorization: fixture.authorization)
        }
        #expect(await fixture.endpointResolver.calls == 1)
        #expect(copiedProvider.addedConfigs.isEmpty)
        await teardownBarrier.release()
        _ = try await first.value

        await fixture.root.endAuthenticatedSession(named: "mcp:first")
        await fixture.root.endAuthenticatedSession(named: "mcp:copied")
    }

    @Test
    func `pending handoff blocks root rebind and release until ownership commits`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(
            rootEnvironment: ["PEEKABOO_BROWSER_MCP_BROWSER_URL": Self.browserURL],
            destinationProviders: [destinationProvider])
        let name = "mcp:pending-root-rebind"
        let pendingDestination = try #require(fixture.root.authenticatedSession(named: name))
        let namespaceGate = try #require(pendingDestination.browserMutationExecutionGate)
        try await namespaceGate.acquire()

        let transfer = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorization: fixture.authorization)
        }
        while fixture.rootProvider.removeCount == 0 {
            await Task.yield()
        }
        let rootResponse = try await BrowserTool(
            client: fixture.root,
            executionPolicy: .foregroundAllowed,
            instructionAudience: .commandLine)
            .execute(arguments: ToolArguments(raw: ["action": "list_pages"]))
        #expect(rootResponse.isError)
        #expect(fixture.rootProvider.addedConfigs.count == 1)
        #expect(fixture.rootProvider.executedTools == ["list_pages"])

        // A disconnected root status/release must not clear ownership claimed by the pending handoff.
        await fixture.root.disconnect()
        await namespaceGate.release()
        let destination = try await transfer.value

        #expect(!fixture.rootProvider.connected)
        #expect(fixture.rootProvider.addedConfigs.count == 1)
        #expect(destinationProvider.connected)
        #expect(destinationProvider.addedConfigs.count == 1)

        #expect(await destination.endAuthenticatedBrowserSession())
        let reconnected = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        #expect(reconnected.isConnected)
        #expect(fixture.rootProvider.addedConfigs.count == 2)
        await fixture.root.disconnect()
    }

    @Test
    func `session teardown waits through source drain before releasing the target`() async throws {
        let teardownBarrier = HandoffBarrier()
        let rootProvider = HandoffProviderSpy(label: "root")
        rootProvider.removeBarrier = teardownBarrier
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let nextProvider = HandoffProviderSpy(label: "next")
        let fixture = try await Self.fixture(
            rootProvider: rootProvider,
            destinationProviders: [destinationProvider, nextProvider])
        let name = "mcp:teardown-during-drain"

        let transfer = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorization: fixture.authorization)
        }
        await teardownBarrier.waitUntilBlocked()

        let endFinished = HandoffCompletionFlag()
        let end = Task { @MainActor in
            let result = await fixture.root.endAuthenticatedSession(named: name)
            await endFinished.finish()
            return result
        }
        while !fixture.pool.isEnding(named: name) {
            await Task.yield()
        }
        #expect(await !endFinished.isFinished)
        #expect(destinationProvider.removeCount == 0)

        await teardownBarrier.release()
        await #expect(throws: BrowserMCPConnectionError.sessionEnded) {
            _ = try await transfer.value
        }
        #expect(await end.value)
        #expect(rootProvider.removeCount == 1)
        #expect(!rootProvider.connected)
        #expect(destinationProvider.removeCount == 1)

        let next = try #require(fixture.root.authenticatedSession(named: "mcp:after-drain-teardown"))
        let reconnected = try await next.connect(channel: nil, browserURL: Self.browserURL)
        #expect(reconnected.isConnected)
        #expect(nextProvider.addedConfigs.count == 1)
        await fixture.root.endAuthenticatedSession(named: "mcp:after-drain-teardown")
    }

    @Test
    func `session teardown waits through destination bootstrap before releasing the target`() async throws {
        let addBarrier = HandoffBarrier()
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.addBarrier = addBarrier
        let nextProvider = HandoffProviderSpy(label: "next")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider, nextProvider])
        let name = "mcp:teardown-during-bootstrap"

        let transfer = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorization: fixture.authorization)
        }
        await addBarrier.waitUntilBlocked()
        let endFinished = HandoffCompletionFlag()
        let end = Task { @MainActor in
            let result = await fixture.root.endAuthenticatedSession(named: name)
            await endFinished.finish()
            return result
        }
        while !fixture.pool.isEnding(named: name) {
            await Task.yield()
        }
        #expect(await !endFinished.isFinished)
        #expect(destinationProvider.removeCount == 0)

        await addBarrier.release()
        await #expect(throws: BrowserMCPConnectionError.sessionEnded) {
            _ = try await transfer.value
        }
        #expect(await end.value)
        #expect(destinationProvider.removeCount == 1)

        let next = try #require(fixture.root.authenticatedSession(named: "mcp:after-bootstrap-teardown"))
        let reconnected = try await next.connect(channel: nil, browserURL: Self.browserURL)
        #expect(reconnected.isConnected)
        #expect(nextProvider.addedConfigs.count == 1)
        await fixture.root.endAuthenticatedSession(named: "mcp:after-bootstrap-teardown")
    }

    @Test
    func `registered session teardown refuses new and existing authenticated handles`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let name = "mcp:ending-admission"
        _ = try fixture.root.createAuthenticatedSession(named: name)
        let sessionID = try #require(fixture.pool.existingSessionID(named: name))
        let lifecycleBarrier = HandoffBarrier()
        let lifecycleHolder = Task { @MainActor in
            try await fixture.pool.withHandoffLifecycle(sessionID) {
                await lifecycleBarrier.block()
            }
        }
        await lifecycleBarrier.waitUntilBlocked()
        let end = Task { @MainActor in
            await fixture.root.endAuthenticatedSession(named: name)
        }
        while !fixture.pool.isEnding(named: name) {
            await Task.yield()
        }

        #expect(fixture.pool.manager(for: sessionID) == nil)
        #expect(fixture.pool.existingManager(for: sessionID) == nil)
        #expect(fixture.pool.capabilities(for: sessionID) == nil)
        #expect(fixture.pool.mutationGate(for: sessionID) == nil)
        #expect(throws: BrowserMCPConnectionError.receiptBindingUnsupported) {
            _ = try fixture.root.createAuthenticatedSession(named: name)
        }
        #expect(fixture.root.existingAuthenticatedSession(named: name) == nil)
        #expect(destinationProvider.addedConfigs.isEmpty)
        #expect(destinationProvider.executedTools.isEmpty)
        #expect(destinationProvider.removeCount == 0)

        await lifecycleBarrier.release()
        _ = try await lifecycleHolder.value
        #expect(await end.value)
    }

    @Test
    func `partial source teardown rolls ownership back only when the same provider is still live`() async throws {
        let rootProvider = HandoffProviderSpy(label: "root")
        rootProvider.leaveConfiguredAfterRemove = true
        rootProvider.leaveConnectedAfterRemove = true
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(
            rootProvider: rootProvider,
            destinationProviders: [destinationProvider])

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:retry-source",
                authorization: fixture.authorization)
        }
        #expect(destinationProvider.addedConfigs.isEmpty)
        #expect(rootProvider.connected)

        rootProvider.leaveConfiguredAfterRemove = false
        rootProvider.leaveConnectedAfterRemove = false
        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:retry-source",
            authorization: fixture.authorization)
        #expect(await (destination.status(channel: nil)).isConnected)
        #expect(rootProvider.removeCount == 2)
        await fixture.root.endAuthenticatedSession(named: "mcp:retry-source")
    }

    @Test
    func `indeterminate source teardown remains transition locked`() async throws {
        let rootProvider = HandoffProviderSpy(label: "root")
        rootProvider.leaveConfiguredAfterRemove = true
        rootProvider.leaveConnectedAfterRemove = false
        let firstProvider = HandoffProviderSpy(label: "first")
        let copiedProvider = HandoffProviderSpy(label: "copied")
        let fixture = try await Self.fixture(
            rootProvider: rootProvider,
            destinationProviders: [firstProvider, copiedProvider])

        do {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:source-recovery",
                authorization: fixture.authorization)
            Issue.record("Expected source recovery to be required")
        } catch let error as BrowserMCPConnectionError {
            if case .handoffRecoveryRequired = error {} else {
                Issue.record("Expected handoff recovery error, got \(error)")
            }
        }
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:copied",
                authorization: fixture.authorization)
        }
        #expect(firstProvider.addedConfigs.isEmpty)
        #expect(copiedProvider.addedConfigs.isEmpty)
        #expect(await fixture.root.endAuthenticatedSession(named: "mcp:source-recovery") == false)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:copied",
                authorization: fixture.authorization)
        }
        rootProvider.leaveConfiguredAfterRemove = false
        #expect(await fixture.root.endAuthenticatedSession(named: "mcp:source-recovery"))
        let recovered = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        #expect(recovered.isConnected)
        await fixture.root.disconnect()
    }

    @Test
    func `cancelled validation leaves root untouched and allows deterministic retry`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let validationBarrier = HandoffBarrier()
        await fixture.endpointResolver.blockNext(at: validationBarrier, thenCancel: true)

        let cancelled = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:cancelled",
                authorization: fixture.authorization)
        }
        await validationBarrier.waitUntilBlocked()
        cancelled.cancel()
        await validationBarrier.release()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        #expect(fixture.rootProvider.removeCount == 0)
        #expect(destinationProvider.addedConfigs.isEmpty)

        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:cancelled",
            authorization: fixture.authorization)
        #expect(await (destination.status(channel: nil)).isConnected)
        await fixture.root.endAuthenticatedSession(named: "mcp:cancelled")
    }

    @Test
    func `cancellation after source drain rolls destination back for same claim retry`() async throws {
        let addBarrier = HandoffBarrier()
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.addBarrier = addBarrier
        destinationProvider.cancelAddAfterBarrier = true
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])

        let cancelled = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:post-drain-cancel",
                authorization: fixture.authorization)
        }
        await addBarrier.waitUntilBlocked()
        cancelled.cancel()
        await addBarrier.release()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        #expect(fixture.rootProvider.removeCount == 1)
        #expect(!destinationProvider.connected)

        destinationProvider.addBarrier = nil
        destinationProvider.cancelAddAfterBarrier = false
        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:post-drain-cancel",
            authorization: fixture.authorization)
        #expect(await (destination.status(channel: nil)).isConnected)
        #expect(fixture.rootProvider.removeCount == 1)
        await fixture.root.endAuthenticatedSession(named: "mcp:post-drain-cancel")
    }

    @Test
    func `post claim provider failure rolls back child and retries only for the same caller`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.addError = HandoffFixtureError.provider
        let copiedProvider = HandoffProviderSpy(label: "copied")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider, copiedProvider])
        let staleService = try #require(fixture.root.authenticatedSession(named: "mcp:owner"))

        await #expect(throws: HandoffFixtureError.self) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:owner",
                authorization: fixture.authorization)
        }
        #expect(fixture.rootProvider.removeCount == 1)
        #expect(!destinationProvider.connected)
        await fixture.endpointResolver.reset()

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await staleService.connect(
                channel: nil,
                browserURL: "http://127.0.0.1:9333/")
        }
        #expect(await fixture.endpointResolver.calls == 0)

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:copied",
                authorization: fixture.authorization)
        }
        #expect(await fixture.endpointResolver.calls == 0)
        #expect(copiedProvider.addedConfigs.isEmpty)

        destinationProvider.addError = nil
        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:owner",
            authorization: fixture.authorization)
        let status = await destination.status(channel: nil)
        #expect(status.isConnected)
        #expect(status.providerSessionEpoch != fixture.sourceBinding.providerSessionEpoch)
        #expect(fixture.rootProvider.removeCount == 1)
        await fixture.root.endAuthenticatedSession(named: "mcp:owner")
        await fixture.root.endAuthenticatedSession(named: "mcp:copied")
    }

    @Test
    func `authorization ID survives retryable destination failure and is consumed on success`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.addError = HandoffFixtureError.provider
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let authorizationID = try await fixture.root.storeConnectionHandoffAuthorization(
            connectionReceipt: fixture.sourceBinding.connectionReceipt)
        let name = "mcp:authorization-retry"

        await #expect(throws: HandoffFixtureError.self) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }
        await #expect(throws: BrowserMCPConnectionError.invalidHandoffAuthorization) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:different-owner",
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }

        destinationProvider.addError = nil
        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: name,
            authorizationID: authorizationID,
            expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        #expect(await (destination.status(channel: nil)).isConnected)
        #expect(destinationProvider.addedConfigs.count == 2)
        #expect(fixture.rootProvider.removeCount == 1)

        await #expect(throws: BrowserMCPConnectionError.invalidHandoffAuthorization) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }
        await fixture.root.endAuthenticatedSession(named: name)
    }

    @Test
    func `authorization ID rejects concurrent replay and discard wins retryable completion`() async throws {
        let addBarrier = HandoffBarrier()
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.addBarrier = addBarrier
        destinationProvider.addError = HandoffFixtureError.provider
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let authorizationID = try await fixture.root.storeConnectionHandoffAuthorization(
            connectionReceipt: fixture.sourceBinding.connectionReceipt)
        let name = "mcp:authorization-discard"

        let transfer = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }
        await addBarrier.waitUntilBlocked()
        await #expect(throws: BrowserMCPConnectionError.invalidHandoffAuthorization) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }
        fixture.root.discardConnectionHandoffAuthorization(authorizationID)
        await addBarrier.release()
        await #expect(throws: HandoffFixtureError.self) {
            _ = try await transfer.value
        }

        destinationProvider.addBarrier = nil
        destinationProvider.addError = nil
        await #expect(throws: BrowserMCPConnectionError.invalidHandoffAuthorization) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }
        await fixture.root.endAuthenticatedSession(named: name)
    }

    @Test
    func `ending session consumes authorization instead of reviving stale retry state`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.addError = HandoffFixtureError.provider
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let authorizationID = try await fixture.root.storeConnectionHandoffAuthorization(
            connectionReceipt: fixture.sourceBinding.connectionReceipt)
        let name = "mcp:authorization-ending"

        await #expect(throws: HandoffFixtureError.self) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }
        destinationProvider.addError = nil
        let sessionID = try #require(fixture.pool.existingSessionID(named: name))
        let lifecycleBarrier = HandoffBarrier()
        let lifecycleHolder = Task { @MainActor in
            try await fixture.pool.withHandoffLifecycle(sessionID) {
                await lifecycleBarrier.block()
            }
        }
        await lifecycleBarrier.waitUntilBlocked()
        let end = Task { @MainActor in
            await fixture.root.endAuthenticatedSession(named: name)
        }
        while !fixture.pool.isEnding(named: name) {
            await Task.yield()
        }

        await #expect(throws: BrowserMCPConnectionError.invalidHandoffAuthorization) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }
        await lifecycleBarrier.release()
        _ = try await lifecycleHolder.value
        #expect(await end.value)
        await #expect(throws: BrowserMCPConnectionError.invalidHandoffAuthorization) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }
    }

    @Test
    func `ending session consumes authorization from the current retryable destination failure`() async throws {
        let addBarrier = HandoffBarrier()
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.addBarrier = addBarrier
        destinationProvider.addError = HandoffFixtureError.provider
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let authorizationID = try await fixture.root.storeConnectionHandoffAuthorization(
            connectionReceipt: fixture.sourceBinding.connectionReceipt)
        let name = "mcp:authorization-current-ending"

        let transfer = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }
        await addBarrier.waitUntilBlocked()
        let end = Task { @MainActor in
            await fixture.root.endAuthenticatedSession(named: name)
        }
        while !fixture.pool.isEnding(named: name) {
            await Task.yield()
        }

        await addBarrier.release()
        await #expect(throws: HandoffFixtureError.self) {
            _ = try await transfer.value
        }
        #expect(await end.value)
        await #expect(throws: BrowserMCPConnectionError.invalidHandoffAuthorization) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }
    }

    @Test
    func `indeterminate child cleanup stays locked until owner teardown confirms removal`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.executeError = HandoffFixtureError.provider
        destinationProvider.leaveConfiguredAfterRemove = true
        destinationProvider.leaveConnectedAfterRemove = true
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])

        do {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:destination-recovery",
                authorization: fixture.authorization)
            Issue.record("Expected destination recovery to be required")
        } catch let error as BrowserMCPConnectionError {
            if case .handoffRecoveryRequired = error {} else {
                Issue.record("Expected handoff recovery error, got \(error)")
            }
        }
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        }
        #expect(await fixture.root.endAuthenticatedSession(named: "mcp:destination-recovery") == false)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        }

        destinationProvider.leaveConfiguredAfterRemove = false
        destinationProvider.leaveConnectedAfterRemove = false
        #expect(await fixture.root.endAuthenticatedSession(named: "mcp:destination-recovery"))
        let reconnected = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        #expect(reconnected.isConnected)
        await fixture.root.disconnect()
    }

    @Test
    func `native handoff revalidates generation signature and listener without browser detection`() async throws {
        let events = HandoffEventLog()
        let rootProvider = HandoffProviderSpy(label: "root")
        rootProvider.events = events
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.events = events
        let browser = DetectedBrowser(
            name: "Google Chrome",
            bundleIdentifier: ChromeChannelIdentity.stable.bundleIdentifier,
            processIdentifier: 421,
            processStartIdentity: 10421,
            version: "151.0",
            channel: .stable)
        let detection = HandoffNativeDetectionSpy(browser: browser)
        let endpoint = BrowserMCPDevToolsEndpoint(
            browserURL: Self.browserURL,
            webSocketDebuggerURL: Self.webSocketURL,
            browserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3",
            listenerIdentity: DarwinProcessLoopbackListenerIdentity(
                processIdentifier: 421,
                processStartIdentity: 10421,
                addressFamily: .ipv4,
                port: 9222,
                kernelSocketAddress: 101,
                kernelProtocolControlBlock: 102,
                kernelGeneration: 103))
        let nativeAuthority = HandoffNativeAuthoritySpy(endpoint: endpoint)
        let externalResolver = HandoffUnexpectedExternalResolverSpy()

        func manager(provider: HandoffProviderSpy) -> BrowserMCPSessionManager {
            BrowserMCPSessionManager(
                serverName: provider.label,
                manager: provider,
                detectedBrowsers: { channel in detection.results(channel: channel) },
                processStartIdentity: { processIdentifier in
                    processIdentifier == 421 ? 10421 : nil
                },
                processBundleIdentifier: { processIdentifier in
                    processIdentifier == 421 ? ChromeChannelIdentity.stable.bundleIdentifier : nil
                },
                processCodeSignatureValidator: { processIdentifier, generation, channel in
                    guard processIdentifier == 421, generation == 10421 else { return nil }
                    return .browserTestIdentity(channel: channel)
                },
                endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                    try await externalResolver.resolve(url)
                },
                channelEndpointResolver: BrowserMCPChannelEndpointResolver(
                    resolveInitial: { _, _ in await nativeAuthority.resolve() },
                    revalidate: { target, expected in
                        try await nativeAuthority.revalidate(target: target, expected: expected)
                    }),
                environment: [:])
        }

        let rootManager = manager(provider: rootProvider)
        let destinationManager = manager(provider: destinationProvider)
        let pool = BrowserMCPAuthenticatedSessionPool { _ in destinationManager }
        let root = BrowserMCPService(
            sessionManager: rootManager,
            authenticatedSessionPool: pool)
        let source = try await root.connect(channel: .stable, browserURL: nil)
        let binding = try BrowserMCPExecutionSessionBinding(
            connectionReceipt: #require(source.connectionReceipt),
            providerSessionEpoch: #require(source.providerSessionEpoch))
        detection.reset()
        await nativeAuthority.reset()
        await externalResolver.reset()
        await events.reset()

        let destination = try await root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:native",
            authorization: root.authorizeConnectionHandoff(
                connectionReceipt: binding.connectionReceipt))

        #expect(detection.calls == 0)
        #expect(await nativeAuthority.revalidationCount == 4)
        #expect(await nativeAuthority.initialResolutionCount == 0)
        #expect(await externalResolver.calls == 0)
        #expect(await events.values == [
            "root.remove",
            "destination.add",
            "destination.execute:list_pages",
        ])
        let config = try #require(destinationProvider.addedConfigs.only)
        #expect(config.args.contains("--wsEndpoint=\(Self.webSocketURL)"))
        let destinationStatus = await destination.status(channel: .stable)
        #expect(destinationStatus.isConnected)
        #expect(destinationStatus.providerSessionEpoch != binding.providerSessionEpoch)
        await root.endAuthenticatedSession(named: "mcp:native")
    }

    private static let browserURL = "http://127.0.0.1:9222/"
    private static let webSocketURL = "ws://127.0.0.1:9222/devtools/browser/browser-a"

    private struct Fixture {
        let root: BrowserMCPService, rootManager: BrowserMCPSessionManager
        let pool: BrowserMCPAuthenticatedSessionPool, rootProvider: HandoffProviderSpy
        let endpointResolver: HandoffEndpointResolverSpy
        let detection: HandoffDetectionSpy
        let events: HandoffEventLog
        let sourceBinding: BrowserMCPExecutionSessionBinding
        let authorization: BrowserMCPConnectionHandoffAuthorization
    }

    private static func fixture(
        rootProvider: HandoffProviderSpy = HandoffProviderSpy(label: "root"),
        rootEnvironment: [String: String] = [:],
        destinationProviders: [HandoffProviderSpy]) async throws -> Fixture
    {
        let events = HandoffEventLog()
        rootProvider.events = events
        for provider in destinationProviders {
            provider.events = events
        }
        let endpointResolver = HandoffEndpointResolverSpy(
            endpoint: BrowserMCPDevToolsEndpoint(
                browserURL: self.browserURL,
                webSocketDebuggerURL: self.webSocketURL,
                browserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3"))
        let detection = HandoffDetectionSpy()
        let rootManager = self.manager(
            provider: rootProvider,
            endpointResolver: endpointResolver,
            detection: detection,
            environment: rootEnvironment)
        var destinationManagers = destinationProviders.map { provider in
            self.manager(
                provider: provider,
                endpointResolver: endpointResolver,
                detection: detection,
                environment: [
                    "PEEKABOO_BROWSER_MCP_BROWSER_URL": "http://127.0.0.1:9999",
                    "PEEKABOO_BROWSER_MCP_ISOLATED": "true",
                ])
        }
        let pool = BrowserMCPAuthenticatedSessionPool { _ in
            destinationManagers.removeFirst()
        }
        let root = BrowserMCPService(
            sessionManager: rootManager,
            authenticatedSessionPool: pool)
        let source = try await root.connect(channel: nil, browserURL: self.browserURL)
        let sourceBinding = try BrowserMCPExecutionSessionBinding(
            connectionReceipt: #require(source.connectionReceipt),
            providerSessionEpoch: #require(source.providerSessionEpoch))
        let authorization = try await root
            .authorizeConnectionHandoff(connectionReceipt: sourceBinding.connectionReceipt)
        await events.reset()
        await endpointResolver.reset()
        detection.reset()
        return Fixture(
            root: root,
            rootManager: rootManager,
            pool: pool,
            rootProvider: rootProvider,
            endpointResolver: endpointResolver,
            detection: detection,
            events: events,
            sourceBinding: sourceBinding,
            authorization: authorization)
    }

    private static func manager(
        provider: HandoffProviderSpy,
        endpointResolver: HandoffEndpointResolverSpy,
        detection: HandoffDetectionSpy,
        environment: [String: String]) -> BrowserMCPSessionManager
    {
        BrowserMCPSessionManager(
            serverName: provider.label,
            manager: provider,
            detectedBrowsers: { _ in
                detection.record()
                return []
            },
            processStartIdentity: { _ in nil },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                try await endpointResolver.resolve(url)
            },
            environment: environment)
    }
}

extension BrowserMCPHandoffSessionTests {
    @Test
    func `confirmed source drain tombstone resolves commit recovery debt`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let name = "mcp:commit-recovery"
        _ = try #require(fixture.root.authenticatedSession(named: name))
        let sessionID = try #require(fixture.pool.existingSessionID(named: name))
        let preparation = try fixture.pool.prepareHandoff(sessionID, authorization: fixture.authorization)
        guard case .start = preparation else {
            Issue.record("Expected a new handoff transaction")
            return
        }

        _ = try await fixture.rootManager.drainConnectionForHandoff(authorization: fixture.authorization)
        fixture.pool.requireSourceRecovery(for: sessionID)
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.rootManager.connectWithOutcome(channel: nil, browserURL: Self.browserURL)
        }
        #expect(fixture.rootProvider.addedConfigs.count == 1)
        #expect(await fixture.root.endAuthenticatedSession(named: name))
        #expect(fixture.pool.isEmpty)
        #expect(await !fixture.rootManager.recoverSourceHandoff(authorization: fixture.authorization))

        let reconnected = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        let replacementEpoch = try #require(reconnected.providerSessionEpoch)
        #expect(replacementEpoch != fixture.sourceBinding.providerSessionEpoch)
        #expect(await !fixture.rootManager.recoverSourceHandoff(authorization: fixture.authorization))
        let replacementStatus = await fixture.root.status(channel: nil)
        #expect(replacementStatus.isConnected)
        #expect(replacementStatus.providerSessionEpoch == replacementEpoch)
        await fixture.root.disconnect()
    }

    @Test
    func `explicit disconnect retires source authorization capacity`() async throws {
        let fixture = try await Self.fixture(destinationProviders: [])
        var authorizationIDs: [UUID] = []
        for _ in 0..<128 {
            try await authorizationIDs.append(fixture.root.storeConnectionHandoffAuthorization(
                connectionReceipt: fixture.sourceBinding.connectionReceipt))
        }
        await #expect(throws: BrowserMCPConnectionError.handoffAuthorizationCapacityExceeded) {
            _ = try await fixture.root.storeConnectionHandoffAuthorization(
                connectionReceipt: fixture.sourceBinding.connectionReceipt)
        }

        await fixture.root.disconnect()
        for authorizationID in try [#require(authorizationIDs.first), #require(authorizationIDs.last)] {
            await #expect(throws: BrowserMCPConnectionError.invalidHandoffAuthorization) {
                _ = try await fixture.root.transferConnection(
                    toAuthenticatedSessionNamed: "mcp:stale-disconnect",
                    authorizationID: authorizationID,
                    expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
            }
        }

        let replacement = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        let replacementReceipt = try #require(replacement.connectionReceipt)
        _ = try await fixture.root.storeConnectionHandoffAuthorization(connectionReceipt: replacementReceipt)
        await fixture.root.disconnect()
    }

    @Test
    func `confirmed source loss retires stored handoff authorizations`() async throws {
        let fixture = try await Self.fixture(destinationProviders: [])
        let authorizationID = try await fixture.root.storeConnectionHandoffAuthorization(
            connectionReceipt: fixture.sourceBinding.connectionReceipt)
        fixture.rootProvider.connected = false

        let status = await fixture.root.status(channel: nil)
        #expect(!status.isConnected)
        #expect(status.observation == .confirmed)
        await #expect(throws: BrowserMCPConnectionError.invalidHandoffAuthorization) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:stale-loss",
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }

        let replacement = try await fixture.root.connect(channel: nil, browserURL: Self.browserURL)
        _ = try await fixture.root.storeConnectionHandoffAuthorization(
            connectionReceipt: #require(replacement.connectionReceipt))
        await fixture.root.disconnect()
    }

    @Test
    func `indeterminate source status retains the exact handoff authorization`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let authorizationID = try await fixture.root.storeConnectionHandoffAuthorization(
            connectionReceipt: fixture.sourceBinding.connectionReceipt)
        let validationBarrier = HandoffBarrier()
        await fixture.endpointResolver.blockNext(at: validationBarrier, thenCancel: true)

        let inspection = Task { @MainActor in
            await fixture.root.status(channel: nil)
        }
        await validationBarrier.waitUntilBlocked()
        inspection.cancel()
        await validationBarrier.release()
        let status = await inspection.value
        #expect(status.observation == .indeterminate)
        #expect(status.connectionReceipt == fixture.sourceBinding.connectionReceipt)
        #expect(status.providerSessionEpoch == fixture.sourceBinding.providerSessionEpoch)

        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:retained-indeterminate",
            authorizationID: authorizationID,
            expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        #expect(await (destination.status(channel: nil)).isConnected)
        #expect(await fixture.root.endAuthenticatedSession(named: "mcp:retained-indeterminate"))
    }

    @Test
    func `successful source drain consumes sibling handoff authorizations`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let transferredID = try await fixture.root.storeConnectionHandoffAuthorization(
            connectionReceipt: fixture.sourceBinding.connectionReceipt)
        let siblingID = try await fixture.root.storeConnectionHandoffAuthorization(
            connectionReceipt: fixture.sourceBinding.connectionReceipt)

        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: "mcp:transferred",
            authorizationID: transferredID,
            expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        #expect(await (destination.status(channel: nil)).isConnected)
        await #expect(throws: BrowserMCPConnectionError.invalidHandoffAuthorization) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:sibling",
                authorizationID: siblingID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }
        #expect(await fixture.root.endAuthenticatedSession(named: "mcp:transferred"))
    }

    @Test
    func `retryable destination authorization survives ended source observation`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.addError = HandoffFixtureError.provider
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let authorizationID = try await fixture.root.storeConnectionHandoffAuthorization(
            connectionReceipt: fixture.sourceBinding.connectionReceipt)
        let name = "mcp:retry-after-source-end"

        await #expect(throws: HandoffFixtureError.self) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorizationID: authorizationID,
                expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        }
        let sourceStatus = await fixture.root.status(channel: nil)
        #expect(!sourceStatus.isConnected)
        #expect(sourceStatus.observation == .confirmed)
        await fixture.root.disconnect()

        destinationProvider.addError = nil
        let destination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: name,
            authorizationID: authorizationID,
            expectedConnectionReceipt: fixture.sourceBinding.connectionReceipt)
        #expect(await (destination.status(channel: nil)).isConnected)
        #expect(await fixture.root.endAuthenticatedSession(named: name))
    }

    @Test
    func `session release cannot erase committed ownership before handoff bootstrap`() async throws {
        let destinationProvider = HandoffProviderSpy(label: "destination")
        let contenderProvider = HandoffProviderSpy(label: "contender")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider, contenderProvider])
        let name = "mcp:committed-before-bootstrap"
        let destination = try #require(fixture.root.authenticatedSession(named: name))
        let sessionID = try #require(fixture.pool.existingSessionID(named: name))
        let destinationManager = try #require(fixture.pool.existingManager(for: sessionID))

        let preparation = try fixture.pool.prepareHandoff(sessionID, authorization: fixture.authorization)
        guard case .start = preparation else {
            Issue.record("Expected a new handoff transaction")
            return
        }
        let target = try await fixture.rootManager.drainConnectionForHandoff(
            authorization: fixture.authorization)
        try await fixture.pool.commitRootHandoff(
            to: sessionID,
            authorization: fixture.authorization,
            target: target)

        let pendingStatus = await destination.status(channel: nil)
        #expect(!pendingStatus.isConnected)
        let contender = try #require(fixture.root.authenticatedSession(named: "mcp:contender"))
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await contender.connect(channel: nil, browserURL: Self.browserURL)
        }
        #expect(contenderProvider.addedConfigs.isEmpty)

        try await destinationManager.bootstrapAuthorizedHandoff(target)
        try fixture.pool.resolveHandoff(for: sessionID, as: .connected)
        #expect(await (destination.status(channel: nil)).isConnected)
        await destination.disconnect()

        let connected = try await contender.connect(channel: nil, browserURL: Self.browserURL)
        #expect(connected.isConnected)
        #expect(contenderProvider.addedConfigs.count == 1)
        #expect(await fixture.root.endAuthenticatedSession(named: name))
        #expect(await fixture.root.endAuthenticatedSession(named: "mcp:contender"))
    }

    @Test
    func `retryable handoff status cannot release target before owner settles`() async throws {
        let failureBarrier = HandoffBarrier()
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.addBarrier = failureBarrier
        destinationProvider.addError = HandoffFixtureError.provider
        let contenderProvider = HandoffProviderSpy(label: "contender")
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider, contenderProvider])
        let name = "mcp:retryable-status-release"
        let destination = try #require(fixture.root.authenticatedSession(named: name))

        let transfer = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorization: fixture.authorization)
        }
        await failureBarrier.waitUntilBlocked()
        let status = Task { @MainActor in
            await destination.status(channel: nil)
        }
        await Task.yield()
        await failureBarrier.release()
        await #expect(throws: HandoffFixtureError.self) {
            _ = try await transfer.value
        }
        #expect(await !status.value.isConnected)

        let contender = try #require(fixture.root.authenticatedSession(named: "mcp:retry-contender"))
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await contender.connect(channel: nil, browserURL: Self.browserURL)
        }
        #expect(contenderProvider.addedConfigs.isEmpty)

        destinationProvider.addBarrier = nil
        destinationProvider.addError = nil
        let connectedDestination = try await fixture.root.transferConnection(
            toAuthenticatedSessionNamed: name,
            authorization: fixture.authorization)
        #expect(await (connectedDestination.status(channel: nil)).isConnected)
        #expect(await fixture.root.endAuthenticatedSession(named: name))

        let connected = try await contender.connect(channel: nil, browserURL: Self.browserURL)
        #expect(connected.isConnected)
        #expect(contenderProvider.addedConfigs.count == 1)
        #expect(await fixture.root.endAuthenticatedSession(named: "mcp:retry-contender"))
    }

    @Test
    func `cancelled pending handoff releases disconnected root ownership`() async throws {
        let preflightBarrier = HandoffBarrier()
        let destinationProvider = HandoffProviderSpy(label: "destination")
        destinationProvider.isConnectedBarrier = preflightBarrier
        let fixture = try await Self.fixture(destinationProviders: [destinationProvider])
        let name = "mcp:root-disconnect-before-drain"

        let transfer = Task { @MainActor in
            try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorization: fixture.authorization)
        }
        await preflightBarrier.waitUntilBlocked()
        await fixture.root.disconnect()
        #expect(fixture.rootProvider.removeCount == 1)
        #expect(!fixture.rootProvider.connected)

        await preflightBarrier.release()
        await #expect(throws: BrowserMCPConnectionError.expectedProviderSessionEpochMismatch) {
            _ = try await transfer.value
        }

        let destination = try #require(fixture.root.authenticatedSession(named: name))
        let connected = try await destination.connect(channel: nil, browserURL: Self.browserURL)
        #expect(connected.isConnected)
        #expect(destinationProvider.addedConfigs.count == 1)
        #expect(await fixture.root.endAuthenticatedSession(named: name))
    }

    @Test
    func `cancelled pending handoff retains live root ownership`() async throws {
        let occupiedProvider = HandoffProviderSpy(label: "occupied")
        occupiedProvider.configured = true
        occupiedProvider.connected = true
        let contenderProvider = HandoffProviderSpy(label: "contender")
        let fixture = try await Self.fixture(destinationProviders: [occupiedProvider, contenderProvider])

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await fixture.root.transferConnection(
                toAuthenticatedSessionNamed: "mcp:occupied",
                authorization: fixture.authorization)
        }
        let rootStatus = await fixture.root.status(channel: nil)
        #expect(rootStatus.isConnected)
        #expect(fixture.rootProvider.removeCount == 0)

        let contender = try #require(fixture.root.authenticatedSession(named: "mcp:contender"))
        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await contender.connect(channel: nil, browserURL: Self.browserURL)
        }
        #expect(contenderProvider.addedConfigs.isEmpty)

        await fixture.root.disconnect()
        let connected = try await contender.connect(channel: nil, browserURL: Self.browserURL)
        #expect(connected.isConnected)
        #expect(contenderProvider.addedConfigs.count == 1)
        #expect(await fixture.root.endAuthenticatedSession(named: "mcp:occupied"))
        #expect(await fixture.root.endAuthenticatedSession(named: "mcp:contender"))
    }
}

@MainActor
private final class HandoffProviderSpy: BrowserMCPManaging {
    let label: String
    var events: HandoffEventLog?
    var connected = false
    var configured = false
    var addedConfigs: [MCPServerConfig] = []
    var executedTools: [String] = []
    var removeCount = 0
    var addError: (any Error)?
    var executeError: (any Error)?
    var addBarrier: HandoffBarrier?
    var cancelAddAfterBarrier = false
    var removeBarrier: HandoffBarrier?
    var isConnectedBarrier: HandoffBarrier?
    var leaveConfiguredAfterRemove = false
    var leaveConnectedAfterRemove = false

    init(label: String) {
        self.label = label
    }

    func hasServer(name _: String) -> Bool {
        self.configured
    }

    func isServerConnected(name _: String) async -> Bool {
        await self.isConnectedBarrier?.block()
        return self.connected
    }

    func serverToolCount(name _: String) async -> Int {
        self.connected ? 29 : 0
    }

    func addServer(name _: String, config: MCPServerConfig) async throws {
        await self.events?.record("\(self.label).add")
        self.addedConfigs.append(config)
        await self.addBarrier?.block()
        if self.cancelAddAfterBarrier {
            try Task.checkCancellation()
        }
        if let addError {
            throw addError
        }
        self.configured = true
        self.connected = true
    }

    func removeServer(name _: String) async {
        await self.events?.record("\(self.label).remove")
        await self.removeBarrier?.block()
        self.removeCount += 1
        self.configured = self.leaveConfiguredAfterRemove
        self.connected = self.leaveConnectedAfterRemove
    }

    func executeTool(
        serverName _: String,
        toolName: String,
        arguments _: [String: Any]) async throws -> ToolResponse
    {
        await self.events?.record("\(self.label).execute:\(toolName)")
        self.executedTools.append(toolName)
        if let executeError {
            throw executeError
        }
        return .text("ok")
    }
}

private actor HandoffEndpointResolverSpy {
    let endpoint: BrowserMCPDevToolsEndpoint
    private(set) var calls = 0
    private var nextBarrier: HandoffBarrier?
    private var cancelAfterBarrier = false

    init(endpoint: BrowserMCPDevToolsEndpoint) {
        self.endpoint = endpoint
    }

    func resolve(_ url: String) async throws -> BrowserMCPDevToolsEndpoint {
        self.calls += 1
        guard BrowserLoopbackEndpoint(browserURL: url)?.canonicalBrowserURL == self.endpoint.browserURL else {
            throw BrowserMCPConnectionError.invalidEndpoint("unexpected endpoint")
        }
        if let nextBarrier = self.nextBarrier {
            self.nextBarrier = nil
            await nextBarrier.block()
            if self.cancelAfterBarrier {
                self.cancelAfterBarrier = false
                try Task.checkCancellation()
                throw CancellationError()
            }
        }
        return self.endpoint
    }

    func blockNext(at barrier: HandoffBarrier, thenCancel: Bool) {
        self.nextBarrier = barrier
        self.cancelAfterBarrier = thenCancel
    }

    func reset() {
        self.calls = 0
    }
}

@MainActor
private final class HandoffDetectionSpy {
    private(set) var calls = 0

    func record() {
        self.calls += 1
    }

    func reset() {
        self.calls = 0
    }
}

@MainActor
private final class HandoffNativeDetectionSpy {
    private let browser: DetectedBrowser
    private(set) var calls = 0

    init(browser: DetectedBrowser) {
        self.browser = browser
    }

    func results(channel: BrowserMCPChannel?) -> [DetectedBrowser] {
        self.calls += 1
        guard channel == nil || channel == self.browser.channel else { return [] }
        return [self.browser]
    }

    func reset() {
        self.calls = 0
    }
}

private actor HandoffNativeAuthoritySpy {
    let endpoint: BrowserMCPDevToolsEndpoint
    private(set) var initialResolutionCount = 0
    private(set) var revalidationCount = 0

    init(endpoint: BrowserMCPDevToolsEndpoint) {
        self.endpoint = endpoint
    }

    func resolve() -> BrowserMCPDevToolsEndpoint {
        self.initialResolutionCount += 1
        return self.endpoint
    }

    func revalidate(
        target: BrowserMCPChannelProcessTarget,
        expected: BrowserMCPDevToolsEndpoint) throws
    {
        self.revalidationCount += 1
        guard target.processIdentifier == 421,
              target.processStartIdentity == 10421,
              target.bundleIdentifier == ChromeChannelIdentity.stable.bundleIdentifier,
              expected == self.endpoint
        else {
            throw BrowserMCPConnectionError.connectionLost("native authority changed")
        }
    }

    func reset() {
        self.initialResolutionCount = 0
        self.revalidationCount = 0
    }
}

private actor HandoffUnexpectedExternalResolverSpy {
    private(set) var calls = 0

    func resolve(_: String) throws -> BrowserMCPDevToolsEndpoint {
        self.calls += 1
        throw BrowserMCPConnectionError.invalidEndpoint("external resolver must not run")
    }

    func reset() {
        self.calls = 0
    }
}

private actor HandoffEventLog {
    private(set) var values: [String] = []

    func record(_ value: String) {
        self.values.append(value)
    }

    func reset() {
        self.values.removeAll()
    }
}

private actor HandoffCompletionFlag {
    private(set) var isFinished = false

    func finish() {
        self.isFinished = true
    }
}

private actor HandoffBarrier {
    private var isBlocked = false
    private var isReleased = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        self.isBlocked = true
        self.blockedWaiters.forEach { $0.resume() }
        self.blockedWaiters.removeAll()
        guard !self.isReleased else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !self.isBlocked else { return }
        await withCheckedContinuation { continuation in
            self.blockedWaiters.append(continuation)
        }
    }

    func release() {
        self.isReleased = true
        self.releaseWaiters.forEach { $0.resume() }
        self.releaseWaiters.removeAll()
    }
}

private enum HandoffFixtureError: Error {
    case provider
}

extension Array {
    fileprivate var only: Element? {
        self.count == 1 ? self[0] : nil
    }
}
