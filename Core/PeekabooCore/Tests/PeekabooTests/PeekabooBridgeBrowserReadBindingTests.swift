import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

extension PeekabooBridgeHandlerMutationSemanticsTests {
    @Test
    @MainActor
    func `attested browser read preserves canonical provider error response`() async throws {
        let services = StubServices()
        services.browserRawIsError = true
        services.browserResponseContent = [
            .object([
                "type": .string("text"),
                "text": .string("invalid read arguments"),
            ]),
        ]
        services.browserResponseStructuredContent = .object([
            "error": .object(["reason": .string("invalid read arguments")]),
        ])
        services.browserActionFailure = .indeterminate(
            evidence: .completionUnknown,
            message: "Provider returned an error response.")
        let request = PeekabooBridgeBrowserExecuteRequest(
            toolName: "list_pages",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.localBrowserReceipt)

        let handled = try await Self.handleCurrent(.browserExecute(request), with: Self.server(services: services))

        #expect(handled.mutation == nil)
        guard case let .browserToolResponse(response) = handled.response else {
            Issue.record("Expected the provider browser error response")
            return
        }
        #expect(response.isError)
        #expect(response.content == services.browserResponseContent)
        #expect(response.structuredContent == services.browserResponseStructuredContent)
        #expect(response.connectionReceipt == Self.localBrowserReceipt)
        #expect(response.completedCallCount == 1)
        #expect(response.dispatchedCallCount == 1)
        #expect(response.actionFailure == nil)
    }

    @Test
    @MainActor
    func `attested browser read refuses a provider without receipt binding`() async throws {
        let services = NonReceiptBrowserExecutionServices()
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions },
            processStartIdentityProvider: { processIdentifier in
                processIdentifier == 42 ? 10042 : nil
            })
        let request = PeekabooBridgeBrowserExecuteRequest(
            toolName: "list_pages",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.localBrowserReceipt)

        do {
            _ = try await Self.handleCurrent(
                .browserExecute(request.binding(to: Self.localBrowserReceipt)),
                with: server)
            Issue.record("Expected receipt-bound read provider refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .operationUnsupported)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(services.legacyExecutionCount == 0)
    }

    @Test
    @MainActor
    func `attested browser read refuses a wrong returned receipt`() async throws {
        let services = StubServices()
        services.browserExecutionReceiptOverride = Self.externalBrowserReceipt
        let server = Self.server(services: services)
        let request = PeekabooBridgeBrowserExecuteRequest(
            toolName: "list_pages",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.localBrowserReceipt)

        do {
            _ = try await Self.handleCurrent(.browserExecute(request), with: server)
            Issue.record("Expected wrong browser read receipt refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
        }
    }
}
