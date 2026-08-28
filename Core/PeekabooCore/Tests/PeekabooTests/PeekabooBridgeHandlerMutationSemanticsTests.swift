import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

// swiftlint:disable:next type_body_length
struct PeekabooBridgeHandlerMutationSemanticsTests {
    @Test
    @MainActor
    func `permission request reports a global foreground native dispatch`() async throws {
        let server = Self.server(postEventAccessRequester: { false })

        let handled = try await server.handleAuthorized(
            .requestPostEventPermission,
            peer: nil,
            permissions: Self.permissions)

        guard case let .bool(granted) = handled.response else {
            Issue.record("Expected the legacy permission bool response")
            return
        }
        #expect(!granted)
        Self.expectDispatched(
            handled,
            mechanism: .nativeFramework,
            mode: .foreground,
            unitCount: 1)
        guard case .global? = handled.mutation?.target else {
            Issue.record("Expected an explicitly global permission target")
            return
        }
    }

    @Test
    @MainActor
    func `browser execution binds a live local browser process when available`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions },
            processStartIdentityProvider: { processIdentifier in
                processIdentifier == 42 ? 10042 : nil
            })

        let handled = try await Self.handleCurrent(
            .browserExecute(.init(
                toolName: "click",
                arguments: [:],
                channel: "stable",
                expectedConnectionReceipt: Self.localBrowserReceipt)),
            with: server)

        guard case let .handlerResolved(target)? = handled.mutation?.target else {
            Issue.record("Expected the browser connection receipt to bind its local process")
            return
        }
        #expect(target.processIdentity == .init(processIdentifier: 42, processStartIdentity: 10042))
    }

    @Test
    @MainActor
    func `browser connect accepts canonical existing connection no change`() async throws {
        let services = StubServices()
        services.browserConnectOutcome = .confirmedNoChange()
        let handled = try await Self.handleCurrent(
            .browserConnect(.init(channel: "stable")),
            with: Self.server(services: services))

        #expect(handled.outcome?.state == .confirmedNoChange)
        #expect(handled.outcome?.delivery == nil)
        #expect(handled.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        guard case let .handlerResolved(target)? = handled.mutation?.target else {
            Issue.record("Expected the existing browser connection to retain its exact process target")
            return
        }
        #expect(target.processIdentity == .init(processIdentifier: 42, processStartIdentity: 10042))
    }

    @Test
    @MainActor
    func `browser execution binds every accepted call and response to one exact browser receipt`() async throws {
        let services = StubServices()
        services.browserResponseStructuredContent = .object([
            "result": .object(["state": .string("accepted")]),
        ])
        let server = Self.server(services: services)
        let request = PeekabooBridgeBrowserExecuteRequest(
            calls: [
                .init(toolName: "click", arguments: ["uid": .string("2_1")]),
                .init(toolName: "type_text", arguments: ["text": .string("value")]),
            ],
            channel: "stable",
            expectedConnectionReceipt: Self.localBrowserReceipt)

        let handled = try await Self.handleCurrent(.browserExecute(request), with: server)

        Self.expectDispatched(
            handled,
            mechanism: .browserProtocol,
            mode: .background,
            unitCount: 2)
        guard case let .handlerResolved(identity)? = handled.mutation?.target else {
            Issue.record("Expected browser execution to retain its exact process target")
            return
        }
        #expect(identity.processIdentity == .init(processIdentifier: 42, processStartIdentity: 10042))
        guard case let .browserToolResponse(response) = handled.response else {
            Issue.record("Expected a receipt-bound browser response")
            return
        }
        #expect(response.connectionReceipt == services.lastExpectedBrowserConnectionReceipt)
        #expect(response.structuredContent == services.browserResponseStructuredContent)
        #expect(services.lastBrowserExecute == request.binding(to: Self.localBrowserReceipt))
    }

    @Test
    @MainActor
    func `browser execution refuses an empty sequence before service dispatch`() async throws {
        let services = StubServices()
        let server = Self.server(services: services)

        do {
            _ = try await Self.handleCurrent(.browserExecute(.init(calls: [])), with: server)
            Issue.record("Expected an empty browser sequence to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .invalidRequest)
            #expect(!failure.outcome.dispatchState.mutationDispatched)
        }
        #expect(services.lastBrowserExecute == nil)
    }

    @Test
    @MainActor
    func `browser execution refuses a stale process generation before service dispatch`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions },
            processStartIdentityProvider: { processIdentifier in
                processIdentifier == 42 ? 20042 : nil
            })

        do {
            _ = try await Self.handleCurrent(
                .browserExecute(.init(
                    toolName: "click",
                    arguments: [:],
                    channel: "stable",
                    expectedConnectionReceipt: Self.localBrowserReceipt)),
                with: server)
            Issue.record("Expected stale browser process generation to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(!failure.outcome.dispatchState.mutationDispatched)
        }
        #expect(services.lastBrowserExecute == nil)
        #expect(services.lastExpectedBrowserConnectionReceipt == nil)
    }

    @Test
    @MainActor
    func `unattested explicit endpoint execution retains the legacy provider path`() async throws {
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
            toolName: "click",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.externalBrowserReceipt)
        let handled = try await server.handleAuthorized(
            .browserExecute(request.binding(to: Self.externalBrowserReceipt)),
            peer: nil,
            permissions: Self.permissions)

        guard case .browserToolResponse = handled.response else {
            Issue.record("Expected the legacy browser response")
            return
        }
        #expect(handled.mutation == nil)
        #expect(services.legacyExecutionCount == 1)
    }

    @Test
    @MainActor
    func `unattested explicit endpoint connect retains the base provider path`() async throws {
        let services = NonReceiptBrowserExecutionServices()
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions },
            processStartIdentityProvider: { processIdentifier in
                processIdentifier == 42 ? 10042 : nil
            })

        let handled = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(false) {
            try await server.handleAuthorized(
                .browserConnect(.init(
                    channel: "stable",
                    browserURL: "http://127.0.0.1:9333")),
                peer: nil,
                permissions: Self.permissions)
        }

        guard case .browserStatus = handled.response else {
            Issue.record("Expected legacy browser status")
            return
        }
        #expect(handled.mutation == nil)
        #expect(services.legacyConnectCount == 1)
    }

    @Test
    @MainActor
    func `attested browser execution refuses a provider without receipt binding`() async throws {
        let services = NonReceiptBrowserExecutionServices()
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions },
            processStartIdentityProvider: { processIdentifier in
                processIdentifier == 42 ? 10042 : nil
            })

        do {
            _ = try await Self.handleCurrent(
                .browserExecute(.init(
                    toolName: "click",
                    arguments: [:],
                    channel: "stable",
                    expectedConnectionReceipt: Self.localBrowserReceipt)),
                with: server)
            Issue.record("Expected a non-receipt-capable browser provider to refuse")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .operationUnsupported)
            #expect(!failure.outcome.dispatchState.mutationDispatched)
        }
        #expect(services.legacyExecutionCount == 0)
    }

    @Test
    func `browser response receipt must match the handler target`() throws {
        let request = PeekabooBridgeRequest.browserExecute(.init(
            toolName: "click",
            arguments: [:],
            channel: "stable"))
        let handlerTarget = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 42,
            processStartIdentity: 10042))
        let response = PeekabooBridgeResponse.browserToolResponse(.init(
            content: [],
            isError: false,
            meta: nil,
            connectionReceipt: .init(
                channel: "stable",
                processIdentifier: 42,
                processStartIdentity: 20042)))

        #expect(throws: DesktopTargetIdentityError.contradictoryProcessGeneration) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolve(
                request: request,
                response: response,
                handledTarget: handlerTarget)
        }
    }

    @Test
    @MainActor
    func `explicit endpoint execution retains its full external browser target`() async throws {
        let services = StubServices()
        let receipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        services.browserConnectionReceipt = receipt
        let handled = try await Self.handleCurrent(
            .browserExecute(.init(
                toolName: "click",
                arguments: [:],
                channel: "stable",
                expectedConnectionReceipt: receipt)),
            with: Self.server(services: services))

        guard case let .externalBrowser(target)? = handled.mutation?.target else {
            Issue.record("Expected a full external browser target")
            return
        }
        #expect(target == receipt)
        guard case let .browserToolResponse(response) = handled.response else {
            Issue.record("Expected a browser response")
            return
        }
        #expect(response.connectionReceipt == receipt)
        #expect(response.completedCallCount == 1)
        #expect(response.dispatchedCallCount == 1)
    }

    @Test
    @MainActor
    func `browser connect binds the exact requested endpoint and channel before signing`() async throws {
        let validReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://localhost:9222/",
            webSocketDebuggerURL: "ws://localhost:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let services = StubServices()
        services.browserConnectionReceipt = validReceipt
        let request = PeekabooBridgeRequest.browserConnect(.init(
            channel: "stable",
            browserURL: "HTTP://LOCALHOST:9222"))

        let handled = try await Self.handleCurrent(request, with: Self.server(services: services))
        guard case let .externalBrowser(target)? = handled.mutation?.target else {
            Issue.record("Expected the explicit connect endpoint to remain externally bound")
            return
        }
        #expect(target == validReceipt)

        let wrongReceipts = [
            PeekabooBridgeBrowserConnectionReceipt(
                channel: "stable",
                browserURL: "http://localhost:9333/",
                webSocketDebuggerURL: "ws://localhost:9333/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3"),
            PeekabooBridgeBrowserConnectionReceipt(
                channel: "canary",
                browserURL: "http://localhost:9222/",
                webSocketDebuggerURL: "ws://localhost:9222/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3"),
            PeekabooBridgeBrowserConnectionReceipt(
                channel: "stable",
                processIdentifier: 42,
                processStartIdentity: 10042,
                bundleIdentifier: "com.google.Chrome",
                browserVersion: "Chrome/151.0"),
        ]

        services.preservesBrowserReceiptChannel = true
        for receipt in wrongReceipts {
            services.browserConnectionReceipt = receipt
            do {
                _ = try await Self.handleCurrent(request, with: Self.server(services: services))
                Issue.record("Expected browser connect target substitution to be rejected")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .indeterminate)
                #expect(failure.outcome.evidence == .completionUnknown)
            }
        }
    }

    @Test
    @MainActor
    func `external browser execution requires the exact request bound endpoint`() async throws {
        let services = StubServices()
        let liveReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-b",
            devToolsBrowserID: "browser-b",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        services.browserConnectionReceipt = liveReceipt
        let staleReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let requests = [
            PeekabooBridgeBrowserExecuteRequest(
                toolName: "click",
                arguments: [:],
                channel: "stable"),
            PeekabooBridgeBrowserExecuteRequest(
                toolName: "click",
                arguments: [:],
                channel: "stable",
                expectedConnectionReceipt: staleReceipt),
        ]

        for request in requests {
            do {
                _ = try await Self.handleCurrent(.browserExecute(request), with: Self.server(services: services))
                Issue.record("Expected external endpoint substitution to be refused")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.retrySafety == .safe)
            }
        }
        #expect(services.lastBrowserExecute == nil)
        #expect(services.lastExpectedBrowserConnectionReceipt == nil)
    }

    @Test
    @MainActor
    func `local browser execution refuses missing or drifted process binding`() async throws {
        let services = StubServices()
        let changedGeneration = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            processIdentifier: 42,
            processStartIdentity: 10043,
            bundleIdentifier: "com.google.Chrome",
            browserVersion: "144.0")
        let requests = [
            PeekabooBridgeBrowserExecuteRequest(
                toolName: "click",
                arguments: [:],
                channel: "stable"),
            PeekabooBridgeBrowserExecuteRequest(
                toolName: "click",
                arguments: [:],
                channel: "stable",
                expectedConnectionReceipt: changedGeneration),
        ]

        for request in requests {
            do {
                _ = try await Self.handleCurrent(.browserExecute(request), with: Self.server(services: services))
                Issue.record("Expected local browser process substitution to be refused")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.dispatchState.mutationDispatched == false)
                #expect(failure.outcome.retrySafety == .safe)
            }
        }
        #expect(services.lastBrowserExecute == nil)
        #expect(services.lastExpectedBrowserConnectionReceipt == nil)
    }

    @Test
    @MainActor
    func `incomplete browser receipts refuse before provider dispatch`() async throws {
        let incompleteReceipts = [
            PeekabooBridgeBrowserConnectionReceipt(
                channel: "stable",
                browserURL: "http://127.0.0.1:9222/",
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a",
                browserVersion: "Chrome/151.0"),
            PeekabooBridgeBrowserConnectionReceipt(
                channel: "stable",
                processIdentifier: 42),
            PeekabooBridgeBrowserConnectionReceipt(
                channel: "stable",
                processIdentifier: 42,
                processStartIdentity: 10042,
                bundleIdentifier: "com.google.Chrome",
                browserURL: "http://127.0.0.1:9222/",
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3"),
        ]

        for receipt in incompleteReceipts {
            let services = StubServices()
            services.browserConnectionReceipt = receipt
            do {
                _ = try await Self.handleCurrent(
                    .browserExecute(.init(toolName: "click", arguments: [:], channel: "stable")),
                    with: Self.server(services: services))
                Issue.record("Expected an incomplete browser receipt to be refused")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.dispatchState == .none)
            }
            #expect(services.lastBrowserExecute == nil)
            #expect(services.lastExpectedBrowserConnectionReceipt == nil)
        }
    }

    @Test
    @MainActor
    func `browser batch failure preserves exact progress and target`() async throws {
        let services = StubServices()
        services.browserResponseStructuredContent = .object([
            "result": .object(["state": .string("partial")]),
        ])
        services.browserCompletedCallCount = 1
        services.browserDispatchedCallCount = 2
        services.browserActionFailure = .indeterminate(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "second call completion unknown",
            hint: "observe before resuming")
        let request = PeekabooBridgeBrowserExecuteRequest(
            calls: [
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "type_text", arguments: [:]),
                .init(toolName: "hover", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: Self.localBrowserReceipt)

        let handled = try await Self.handleCurrent(
            .browserExecute(request),
            with: Self.server(services: services))

        #expect(handled.outcome?.state == .indeterminate)
        #expect(handled.outcome?.dispatchState.unitCount?.rawValue == 2)
        guard case .handlerResolved? = handled.mutation?.target else {
            Issue.record("Expected the failed batch to retain its process target")
            return
        }
        guard case let .browserToolResponse(response) = handled.response else {
            Issue.record("Expected a browser response")
            return
        }
        #expect(response.completedCallCount == 1)
        #expect(response.dispatchedCallCount == 2)
        #expect(response.structuredContent == services.browserResponseStructuredContent)
        #expect(response.actionFailure?.outcome.route == .bridge)
        #expect(response.actionFailure?.outcome.retrySafety == .unsafe)
    }

    @Test
    @MainActor
    func `browser zero progress refusal remains retry safe and dispatch free`() async throws {
        let services = StubServices()
        services.browserResponseStructuredContent = .object([
            "error": .object(["reason": .string("target unavailable")]),
        ])
        services.browserCompletedCallCount = 0
        services.browserDispatchedCallCount = 0
        services.browserActionFailure = .preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Browser target disappeared before dispatch")

        let handled = try await Self.handleCurrent(
            .browserExecute(.init(
                toolName: "click",
                arguments: [:],
                channel: "stable",
                expectedConnectionReceipt: Self.localBrowserReceipt)),
            with: Self.server(services: services))

        #expect(handled.outcome?.state == .refused)
        #expect(handled.outcome?.dispatchState.mutationDispatched == false)
        #expect(handled.outcome?.retrySafety == .safe)
        guard case let .browserToolResponse(response) = handled.response else {
            Issue.record("Expected a typed zero-progress browser response")
            return
        }
        #expect(response.isError)
        #expect(response.completedCallCount == 0)
        #expect(response.dispatchedCallCount == 0)
        #expect(response.structuredContent == services.browserResponseStructuredContent)
        #expect(response.actionFailure?.outcome.route == .bridge)
        #expect(response.actionFailure?.outcome.dispatchState.mutationDispatched == false)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `contradictory browser zero progress result becomes indeterminate`(hasUnsafeFailure: Bool) async throws {
        let services = StubServices()
        services.browserCompletedCallCount = 0
        services.browserDispatchedCallCount = 0
        if hasUnsafeFailure {
            services.browserActionFailure = .indeterminate(
                delivery: .init(mechanism: .browserProtocol, mode: .background),
                evidence: .completionUnknown,
                message: "Contradictory unsafe zero-progress result")
        }

        do {
            _ = try await Self.handleCurrent(
                .browserExecute(.init(
                    toolName: "click",
                    arguments: [:],
                    channel: "stable",
                    expectedConnectionReceipt: Self.localBrowserReceipt)),
                with: Self.server(services: services))
            Issue.record("Expected contradictory zero-progress semantics to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    @MainActor
    func `opaque mid batch browser cancellation leaves progress unknown`() async throws {
        let services = StubServices()
        services.browserExecutionErrorAfterDispatch = CancellationError()
        let request = PeekabooBridgeBrowserExecuteRequest(
            calls: [
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "type_text", arguments: [:]),
                .init(toolName: "hover", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: Self.localBrowserReceipt)

        let handled = try await Self.handleCurrent(
            .browserExecute(request),
            with: Self.server(services: services))

        #expect(handled.outcome?.state == .indeterminate)
        #expect(handled.outcome?.dispatchState.unitCount == nil)
        #expect(handled.outcome?.retrySafety == .unsafe)
        guard case let .browserToolResponse(response) = handled.response else {
            Issue.record("Expected a typed browser cancellation response")
            return
        }
        #expect(response.isError)
        #expect(response.completedCallCount == nil)
        #expect(response.dispatchedCallCount == nil)
        #expect(response.actionFailure?.outcome.dispatchState.unitCount == nil)
        #expect(response.actionFailure?.outcome.retrySafety == .unsafe)
    }

    @Test
    @MainActor
    func `bare provider cancellation before its first call is still unsafe and progress unknown`() async throws {
        let services = StubServices()
        services.browserExecutionError = CancellationError()

        let handled = try await Self.handleCurrent(
            .browserExecute(.init(
                toolName: "click",
                arguments: [:],
                channel: "stable",
                expectedConnectionReceipt: Self.localBrowserReceipt)),
            with: Self.server(services: services))

        #expect(services.lastBrowserExecute == nil)
        #expect(handled.outcome?.state == .indeterminate)
        #expect(handled.outcome?.dispatchState.unitCount == nil)
        #expect(handled.outcome?.retrySafety == .unsafe)
        guard case .handlerResolved? = handled.mutation?.target,
              case let .browserToolResponse(response) = handled.response
        else {
            Issue.record("Expected a target-bound opaque cancellation response")
            return
        }
        #expect(response.completedCallCount == nil)
        #expect(response.dispatchedCallCount == nil)
        #expect(response.actionFailure?.outcome.retrySafety == .unsafe)
    }

    @Test
    @MainActor
    func `observation only carries mutation semantics for focus capable requests`() async throws {
        let server = Self.server()
        let passive = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: .init(focus: .background),
            detection: .init(mode: .none))
        let passiveHandled = try await server.handleAuthorized(
            .desktopObservation(passive),
            peer: nil,
            permissions: Self.permissions)
        #expect(passiveHandled.mutation == nil)

        let webFocus = DesktopObservationRequest(
            target: .screen(index: 0),
            capture: .init(focus: .background),
            detection: .init(mode: .accessibility, allowWebFocusFallback: true))
        let webFocusHandled = try await server.handleAuthorized(
            .desktopObservation(webFocus),
            peer: nil,
            permissions: Self.permissions)
        Self.expectDispatched(
            webFocusHandled,
            mechanism: .capturePipeline,
            mode: .background,
            unitCount: 1)
        guard case .global? = webFocusHandled.mutation?.target else {
            Issue.record("Expected a screen observation to remain global")
            return
        }

        let foreground = DesktopObservationRequest(
            target: .frontmost,
            capture: .init(focus: .foreground),
            detection: .init(mode: .none))
        let foregroundHandled = try await server.handleAuthorized(
            .desktopObservation(foreground),
            peer: nil,
            permissions: Self.permissions)
        Self.expectDispatched(
            foregroundHandled,
            mechanism: .capturePipeline,
            mode: .foreground,
            unitCount: 1)
        guard case .responseResolved? = foregroundHandled.mutation?.target else {
            Issue.record("Expected the foreground target to come from the observation response")
            return
        }
    }

    @Test
    @MainActor
    func `attested browser cancellation before status or receipt-bound dispatch stays retry safe`() async throws {
        let services = StubServices()
        let server = Self.server(services: services)

        services.browserStatusError = CancellationError()
        try await Self.expectBrowserCancellation(from: server)
        #expect(services.lastBrowserExecute == nil)

        services.browserStatusError = nil
        services.browserExecutionError = DesktopActionFailure.preDispatchRefusal(
            reason: .requestCancelled,
            message: "Browser execution was cancelled before tool dispatch.",
            hint: "Submit a new request only if the browser action is still wanted.")
        try await Self.expectBrowserCancellation(from: server)
        #expect(services.lastBrowserExecute == nil)
    }

    @Test
    @MainActor
    func `browser cancellation after provider dispatch stays bound and retry unsafe`() async throws {
        let services = StubServices()
        services.browserExecutionErrorAfterDispatch = CancellationError()
        let handled = try await Self.handleCurrent(
            .browserExecute(.init(
                toolName: "click",
                arguments: [:],
                channel: "stable",
                expectedConnectionReceipt: Self.localBrowserReceipt)),
            with: Self.server(services: services))

        #expect(services.lastBrowserExecute != nil)
        #expect(handled.outcome?.state == .indeterminate)
        #expect(handled.outcome?.dispatchState.unitCount == nil)
        #expect(handled.outcome?.retrySafety == .unsafe)
        guard case .handlerResolved? = handled.mutation?.target,
              case let .browserToolResponse(response) = handled.response
        else {
            Issue.record("Expected a target-bound browser cancellation response")
            return
        }
        #expect(response.isError)
        #expect(response.completedCallCount == nil)
        #expect(response.dispatchedCallCount == nil)
        #expect(response.actionFailure?.outcome == handled.outcome)
    }

    @Test
    @MainActor
    func `untyped browser provider error becomes bound typed indeterminate progress`() async throws {
        let services = StubServices()
        services.browserRawIsError = true
        let request = PeekabooBridgeBrowserExecuteRequest(
            calls: [
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "type_text", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: Self.localBrowserReceipt)

        let handled = try await Self.handleCurrent(.browserExecute(request), with: Self.server(services: services))

        #expect(handled.outcome?.state == .indeterminate)
        #expect(handled.outcome?.dispatchState.unitCount?.rawValue == 2)
        #expect(handled.outcome?.retrySafety == .unsafe)
        guard case .handlerResolved? = handled.mutation?.target,
              case let .browserToolResponse(response) = handled.response
        else {
            Issue.record("Expected a target-bound typed browser error")
            return
        }
        #expect(response.isError)
        #expect(response.completedCallCount == 2)
        #expect(response.dispatchedCallCount == 2)
        #expect(response.actionFailure?.outcome == handled.outcome)
    }

    @Test
    @MainActor
    func `unattested browser provider error remains the raw legacy response`() async throws {
        let services = StubServices()
        services.browserRawIsError = true
        let request = PeekabooBridgeBrowserExecuteRequest(
            toolName: "click",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.externalBrowserReceipt)
        let handled = try await Self.server(services: services).handleAuthorized(
            .browserExecute(request.binding(to: Self.externalBrowserReceipt)),
            peer: nil,
            permissions: Self.permissions)

        #expect(handled.mutation == nil)
        guard case let .browserToolResponse(response) = handled.response else {
            Issue.record("Expected the raw legacy browser response")
            return
        }
        #expect(response.isError)
        #expect(response.actionFailure == nil)
        #expect(response.connectionReceipt == nil)
        #expect(response.completedCallCount == nil)
        #expect(response.dispatchedCallCount == nil)
    }

    @Test
    @MainActor
    func `target resolution refusal preserves safe no-dispatch semantics without a receipt`() async throws {
        let services = StubServices()
        let refusal = DesktopActionOutcome.refused(reason: .targetUnavailable)
        services.automationStub.actionOutcome = refusal

        do {
            _ = try await Self.handleCurrent(
                .click(.init(target: .elementId("B404"), clickType: .single)),
                with: Self.server(services: services))
            Issue.record("Expected unresolved element targeting to remain refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == refusal)
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.targetReceipt == nil)
        }
    }

    @Test
    @MainActor
    func `protocol 1 29 focus capable detection requires a live exact target before dispatch`() async throws {
        let services = StubServices()
        let server = Self.server(services: services)
        let incomplete = WindowContext(
            applicationProcessId: 123,
            windowID: 77,
            windowBounds: Self.bounds,
            shouldFocusWebContent: true)

        for request in [
            PeekabooBridgeRequest.detectElements(.init(
                imageData: Data(),
                snapshotId: "detect",
                windowContext: incomplete)),
            PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: incomplete)),
        ] {
            do {
                _ = try await Self.handleCurrent(request, with: server)
                Issue.record("Expected \(request.operation.rawValue) to refuse incomplete target identity")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.refusalReason == .invalidRequest)
                #expect(!failure.outcome.dispatchState.mutationDispatched)
            }
        }
    }

    @Test
    @MainActor
    func `protocol 1 29 focus capable detection revalidates its exact target before dispatch`() async throws {
        let server = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions },
            windowOwnerProcessIdentifierProvider: { _ in 123 },
            windowBoundsProvider: { _ in Self.bounds },
            processStartIdentityProvider: { _ in 999 })

        for request in [
            PeekabooBridgeRequest.detectElements(.init(
                imageData: Data(),
                snapshotId: "detect",
                windowContext: Self.exactWindowContext)),
            PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: Self.exactWindowContext)),
        ] {
            do {
                _ = try await Self.handleCurrent(request, with: server)
                Issue.record("Expected \(request.operation.rawValue) to refuse a stale target identity")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.refusalReason == .targetUnavailable)
                #expect(!failure.outcome.dispatchState.mutationDispatched)
            }
        }
    }

    @Test
    @MainActor
    func `protocol 1 29 focus capable detection and inspection record exact target dispositions`() async throws {
        let server = Self.serverWithExactWindow()
        let context = Self.exactWindowContext
        let detect = try await Self.handleCurrent(
            .detectElements(.init(imageData: Data(), snapshotId: "detect", windowContext: context)),
            with: server)
        Self.expectDispatched(
            detect,
            mechanism: .accessibilityAction,
            mode: .background,
            unitCount: 1)
        guard case let .handlerResolved(target)? = detect.mutation?.target else {
            Issue.record("Expected detection to carry its handler-validated target")
            return
        }
        #expect(target.exactWindow?.identity.hasSameStableReceipt(as: Self.windowIdentity) == true)

        let inspect = try await Self.handleCurrent(
            .inspectAccessibilityTree(.init(windowContext: context)),
            with: server)
        Self.expectDispatched(
            inspect,
            mechanism: .accessibilityAction,
            mode: .background,
            unitCount: 1)
        guard case .responseResolved? = inspect.mutation?.target else {
            Issue.record("Expected inspection to bind its returned exact window context")
            return
        }
    }

    @Test
    func `protocol 1 28 focus capable detection preserves legacy routing without exact receipts`() async throws {
        let root = URL(
            fileURLWithPath: "/tmp/peekaboo-legacy-focus-detection-\(UUID().uuidString)",
            isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyVersion = PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: legacyVersion...legacyVersion,
                allowedOperations: [.detectElements, .inspectAccessibilityTree])
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.legacy-focus-detection-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: legacyVersion)
        #expect(handshake.negotiatedVersion == PeekabooBridgeProtocolVersion(major: 1, minor: 28))
        #expect(handshake.operationAttestation == nil)
        #expect(handshake.operationSessionAttestation == nil)

        let receiptlessContext = WindowContext(
            applicationProcessId: 123,
            windowID: 77,
            windowBounds: Self.bounds,
            shouldFocusWebContent: true)
        let detection = try await client.detectElements(
            in: Data(),
            snapshotId: "detect",
            windowContext: receiptlessContext)
        let inspection = try await client.inspectAccessibilityTree(windowContext: receiptlessContext)

        #expect(detection.snapshotId == "s")
        #expect(inspection.snapshotId == "inspect")
        #expect(inspection.metadata.windowContext?.windowMutationIdentity == nil)
        await host.stop()
    }

    @Test
    @MainActor
    func `pointer gestures report global foreground event dispatch`() async throws {
        let server = Self.server()
        let requests: [PeekabooBridgeRequest] = [
            .swipe(.init(
                from: .init(x: 1, y: 2),
                to: .init(x: 3, y: 4),
                duration: 10,
                steps: 2,
                profile: .linear)),
            .drag(.init(.init(
                from: .init(x: 1, y: 2),
                to: .init(x: 3, y: 4),
                duration: 10,
                steps: 2,
                modifiers: nil,
                profile: .linear))),
            .moveMouse(.init(
                to: .init(x: 3, y: 4),
                duration: 10,
                steps: 2,
                profile: .linear)),
        ]

        for request in requests {
            let handled = try await server.handleAuthorized(request, peer: nil, permissions: Self.permissions)
            Self.expectDispatched(
                handled,
                mechanism: .globalEvents,
                mode: .foreground,
                unitCount: 1)
            guard case .global? = handled.mutation?.target else {
                Issue.record("Expected \(request.operation.rawValue) to remain desktop-global")
                continue
            }
        }
    }

    @Test
    @MainActor
    func `foreground close carries pinned target and honest fallback outcome`() async throws {
        let windows = HandlerMutationWindowService()
        let server = Self.server(services: StubServices(windows: windows))

        let handled = try await server.handleAuthorized(
            .closeWindow(.init(target: .windowId(77), expectedIdentity: Self.windowIdentity)),
            peer: nil,
            permissions: Self.permissions)

        #expect(handled.outcome?.state == .confirmedChange)
        #expect(handled.outcome?.delivery == .init(mechanism: .composite, mode: .foreground))
        #expect(handled.outcome?.dispatchState.unitCount?.rawValue == 2)
        guard case .requestPinned? = handled.mutation?.target else {
            Issue.record("Expected foreground close to retain its request-pinned window")
            return
        }
        let close = await windows.recordedClose()
        guard case let .windowId(windowID)? = close?.target else {
            Issue.record("Expected the close service to receive the exact window ID")
            return
        }
        #expect(windowID == 77)
        #expect(close?.identity.hasSameStableReceipt(as: Self.windowIdentity) == true)
        #expect(close?.allowForegroundFallback == true)
    }

    @Test
    @MainActor
    func `current close treats a window not found readback as a proved absent target`() async throws {
        let cases: [(request: PeekabooBridgeRequest, mode: DesktopActionOutcome.Delivery.Mode, fallback: Bool)] = [
            (
                .closeWindow(.init(target: .windowId(77), expectedIdentity: Self.windowIdentity)),
                .foreground,
                true),
            (
                .backgroundCloseWindow(.init(target: .windowId(77), expectedIdentity: Self.windowIdentity)),
                .background,
                false),
        ]

        for testCase in cases {
            let windows = HandlerMutationWindowService(
                readbackError: .windowNotFound(criteria: "windowId 77"))
            let handled = try await Self.handleCurrent(
                testCase.request,
                with: Self.server(services: StubServices(windows: windows)))

            guard case .window(nil) = handled.response else {
                Issue.record("Expected the missing post-close window to be returned as nil")
                continue
            }
            #expect(handled.outcome?.state == .confirmedChange)
            #expect(handled.outcome?.delivery?.mode == testCase.mode)
            guard case .requestPinned? = handled.mutation?.target else {
                Issue.record("Expected current close to retain its request-pinned window")
                continue
            }
            #expect(await windows.recordedClose()?.allowForegroundFallback == testCase.fallback)
        }
    }

    @Test
    @MainActor
    func `current window mutations keep other readback failures indeterminate`() async throws {
        let cases: [(request: PeekabooBridgeRequest, error: PeekabooError)] = [
            (
                .closeWindow(.init(target: .windowId(77), expectedIdentity: Self.windowIdentity)),
                .commandFailed("fixture readback failure")),
            (
                .maximizeWindow(.init(target: .windowId(77), expectedIdentity: Self.windowIdentity)),
                .windowNotFound(criteria: "windowId 77")),
        ]

        for testCase in cases {
            let windows = HandlerMutationWindowService(readbackError: testCase.error)
            do {
                _ = try await Self.handleCurrent(
                    testCase.request,
                    with: Self.server(services: StubServices(windows: windows)))
                Issue.record("Expected an unrecognized post-mutation readback failure to be indeterminate")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .indeterminate)
                #expect(failure.outcome.evidence == .completionUnknown)
                #expect(failure.outcome.retrySafety == .unsafe)
            }
        }
    }

    @Test
    @MainActor
    func `current close refuses receiptless provider before dispatch`() async throws {
        let windows = ReceiptlessCloseWindowService()
        let server = Self.server(services: StubServices(windows: windows))

        do {
            _ = try await Self.handleCurrent(
                .closeWindow(.init(target: .windowId(77), expectedIdentity: Self.windowIdentity)),
                with: server)
            Issue.record("Expected current close to require a canonical result provider")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(await windows.closeCount == 0)
    }

    @Test
    @MainActor
    func `focus carries provider outcome and exact target without Bridge fabrication`() async throws {
        let windows = HandlerMutationWindowService()
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions },
            windowOwnerProcessIdentifierProvider: { _ in 123 },
            windowBoundsProvider: { _ in Self.bounds },
            processStartIdentityProvider: { _ in 456 })

        let handled = try await Self.handleCurrent(
            .focusWindow(.init(target: .windowId(77), expectedIdentity: Self.windowIdentity)),
            with: server)

        Self.expectDispatched(
            handled,
            mechanism: .composite,
            mode: .foreground,
            unitCount: 3)
        guard case let .handlerResolved(target)? = handled.mutation?.target else {
            Issue.record("Expected focus to carry its provider-resolved exact window")
            return
        }
        #expect(target.exactWindow?.identity.hasSameStableReceipt(as: Self.windowIdentity) == true)
    }

    @Test
    @MainActor
    func `confirmed maximize carries exact server derived visible work area proof`() async throws {
        let visibleWorkArea = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let providerConfirmedBounds = CGRect(x: 0.5, y: -0.5, width: 1439.5, height: 900.5)
        let readbackIdentity = WindowMutationIdentity(
            windowID: Self.windowIdentity.windowID,
            ownerProcessIdentifier: Self.windowIdentity.ownerProcessIdentifier,
            ownerProcessStartIdentity: Self.windowIdentity.ownerProcessStartIdentity,
            capturedBounds: providerConfirmedBounds)
        let readback = ServiceWindowInfo(
            windowID: Self.windowIdentity.windowID,
            title: "Fixture",
            bounds: providerConfirmedBounds,
            mutationIdentity: readbackIdentity)
        let outcomes: [DesktopActionOutcome] = [
            .confirmedChange(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                unitCount: .one),
            .confirmedNoChange(),
        ]

        for outcome in outcomes {
            let windows = HandlerMutationWindowService(
                maximizeOutcome: outcome,
                readback: readback)
            let server = PeekabooBridgeServer(
                services: StubServices(windows: windows),
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in Self.permissions },
                maximizedVisibleWorkAreaProvider: { _ in visibleWorkArea })

            let handled = try await Self.handleCurrent(
                .maximizeWindow(.init(
                    target: .windowId(Self.windowIdentity.windowID),
                    expectedIdentity: Self.windowIdentity)),
                with: server)

            guard case let .window(window?) = handled.response else {
                Issue.record("Expected a proved maximize window response")
                continue
            }
            #expect(window.mutationPostconditionEvidence?.isMaximized == true)
            #expect(window.mutationPostconditionEvidence?.verifiedVisibleWorkArea == visibleWorkArea)
        }
    }

    @Test
    @MainActor
    func `confirmed maximize rejects a server visible work area mismatch`() async throws {
        let readbackBounds = CGRect(x: 0, y: 0, width: 1438.5, height: 900)
        let readback = ServiceWindowInfo(
            windowID: Self.windowIdentity.windowID,
            title: "Fixture",
            bounds: readbackBounds,
            mutationIdentity: .init(
                windowID: Self.windowIdentity.windowID,
                ownerProcessIdentifier: Self.windowIdentity.ownerProcessIdentifier,
                ownerProcessStartIdentity: Self.windowIdentity.ownerProcessStartIdentity,
                capturedBounds: readbackBounds))
        let windows = HandlerMutationWindowService(
            maximizeOutcome: .confirmedNoChange(),
            readback: readback)
        let server = PeekabooBridgeServer(
            services: StubServices(windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions },
            maximizedVisibleWorkAreaProvider: { _ in CGRect(x: 0, y: 0, width: 1440, height: 900) })

        do {
            _ = try await Self.handleCurrent(
                .maximizeWindow(.init(
                    target: .windowId(Self.windowIdentity.windowID),
                    expectedIdentity: Self.windowIdentity)),
                with: server)
            Issue.record("Expected the unproved maximize result to become indeterminate")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
        }
    }

    @MainActor
    static func server(
        services: StubServices = StubServices(),
        postEventAccessRequester: @escaping @MainActor @Sendable () -> Bool = { true })
        -> PeekabooBridgeServer
    {
        PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessRequester: postEventAccessRequester,
            permissionStatusEvaluator: { _ in Self.permissions },
            processStartIdentityProvider: { processIdentifier in
                processIdentifier == 42 ? 10042 : nil
            })
    }

    @MainActor
    private static func serverWithExactWindow() -> PeekabooBridgeServer {
        PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions },
            windowOwnerProcessIdentifierProvider: { _ in 123 },
            windowBoundsProvider: { _ in Self.bounds },
            processStartIdentityProvider: { _ in 456 })
    }

    @MainActor
    static func handleCurrent(
        _ request: PeekabooBridgeRequest,
        with server: PeekabooBridgeServer) async throws -> PeekabooBridgeHandledResponse
    {
        let request = if case let .browserExecute(payload) = request,
                         let receipt = payload.expectedConnectionReceipt
        {
            PeekabooBridgeRequest.browserExecute(payload.binding(to: receipt))
        } else {
            request
        }
        return try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.current) {
            try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try await server.handleAuthorized(request, peer: nil, permissions: Self.permissions)
            }
        }
    }

    @MainActor
    private static func expectBrowserCancellation(from server: PeekabooBridgeServer) async throws {
        do {
            _ = try await self.handleCurrent(
                .browserExecute(.init(
                    toolName: "click",
                    arguments: [:],
                    channel: "stable",
                    expectedConnectionReceipt: self.localBrowserReceipt)),
                with: server)
            Issue.record("Expected browser execution cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.escalation == .none)
        }
    }

    private static func expectDispatched(
        _ handled: PeekabooBridgeHandledResponse,
        mechanism: DesktopActionOutcome.Delivery.Mechanism,
        mode: DesktopActionOutcome.Delivery.Mode,
        unitCount: Int,
        sourceLocation: SourceLocation = #_sourceLocation)
    {
        #expect(handled.outcome?.state == .dispatchedUnverified, sourceLocation: sourceLocation)
        #expect(handled.outcome?.delivery == .init(mechanism: mechanism, mode: mode), sourceLocation: sourceLocation)
        #expect(
            handled.outcome?.dispatchState.unitCount?.rawValue == unitCount,
            sourceLocation: sourceLocation)
    }

    private static let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
    static let localBrowserReceipt = PeekabooBridgeBrowserConnectionReceipt(
        channel: "stable",
        processIdentifier: 42,
        processStartIdentity: 10042,
        bundleIdentifier: "com.google.Chrome",
        browserURL: "http://127.0.0.1:9222/",
        webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
        devToolsBrowserID: "browser-a",
        browserVersion: "Chrome/144.0",
        protocolVersion: "1.3")
    static let externalBrowserReceipt = PeekabooBridgeBrowserConnectionReceipt(
        channel: "stable",
        browserURL: "http://127.0.0.1:9333/",
        webSocketDebuggerURL: "ws://127.0.0.1:9333/devtools/browser/browser-b",
        devToolsBrowserID: "browser-b",
        browserVersion: "Chrome/144.0",
        protocolVersion: "1.3")
    private static let windowIdentity = WindowMutationIdentity(
        windowID: 77,
        ownerProcessIdentifier: 123,
        ownerProcessStartIdentity: 456,
        capturedBounds: Self.bounds)
    private static let exactWindowContext = WindowContext(
        applicationProcessId: 123,
        windowID: 77,
        windowBounds: Self.bounds,
        windowMutationIdentity: Self.windowIdentity,
        shouldFocusWebContent: true)
    static let permissions = PermissionsStatus(
        screenRecording: true,
        accessibility: true,
        postEvent: true)
}

@MainActor
final class NonReceiptBrowserExecutionServices: PeekabooBridgeServiceProviding {
    private let base = StubServices()
    private(set) var legacyExecutionCount = 0
    private(set) var legacyConnectCount = 0

    var permissions: PermissionsService {
        self.base.permissions
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var menu: any MenuServiceProtocol {
        self.base.menu
    }

    var dock: any DockServiceProtocol {
        self.base.dock
    }

    var dialogs: any DialogServiceProtocol {
        self.base.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.base.desktopObservation
    }

    func browserStatus(channel: String?) async throws -> PeekabooBridgeBrowserStatus {
        try await self.base.browserStatus(channel: channel)
    }

    func browserConnect(channel: String?, browserURL: String?) async throws -> PeekabooBridgeBrowserStatus {
        self.legacyConnectCount += 1
        return try await self.base.browserConnect(channel: channel, browserURL: browserURL)
    }

    func browserExecute(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
        -> PeekabooBridgeBrowserToolResponse
    {
        self.legacyExecutionCount += 1
        return try await self.base.browserExecute(request)
    }
}

@MainActor
extension StubAutomationService {
    func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        ElementDetectionResult(
            snapshotId: "inspect",
            screenshotPath: "/tmp/inspect.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "stub",
                warnings: [],
                windowContext: windowContext,
                isDialog: false))
    }
}

private final class HandlerMutationWindowService: WindowManagementServiceProtocol,
    WindowManagementActionResultProviding,
    WindowManagementPinnedFocusActionResultProviding
{
    private let recorder = HandlerMutationWindowRecorder()
    private let maximizeOutcome: DesktopActionOutcome
    private let readback: ServiceWindowInfo?
    private let readbackError: PeekabooError?

    init(
        maximizeOutcome: DesktopActionOutcome = .confirmedNoChange(),
        readback: ServiceWindowInfo? = nil,
        readbackError: PeekabooError? = nil)
    {
        self.maximizeOutcome = maximizeOutcome
        self.readback = readback
        self.readbackError = readbackError
    }

    func closeWindow(target _: WindowTarget) async throws {}

    func closeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws
    {
        await self.recorder.record(
            target: target,
            identity: expectedIdentity,
            allowForegroundFallback: allowForegroundFallback)
    }

    func closeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws -> DesktopActionResult<Void>
    {
        try await self.closeWindow(
            target: target,
            expectedIdentity: expectedIdentity,
            allowForegroundFallback: allowForegroundFallback)
        let delivery: DesktopActionOutcome.Delivery = allowForegroundFallback
            ? .init(mechanism: .composite, mode: .foreground)
            : .init(mechanism: .accessibilityAction, mode: .background)
        return DesktopActionResult(outcome: .confirmedChange(
            delivery: delivery,
            unitCount: DesktopActionOutcome.DispatchUnitCount(allowForegroundFallback ? 2 : 1)))
    }

    func minimizeWindowActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        DesktopActionResult(outcome: .confirmedNoChange())
    }

    func restoreWindowActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        DesktopActionResult(outcome: .confirmedNoChange())
    }

    func maximizeWindowActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        DesktopActionResult(outcome: self.maximizeOutcome)
    }

    func moveWindowActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGPoint) async throws -> DesktopActionResult<Void>
    {
        DesktopActionResult(outcome: .confirmedNoChange())
    }

    func resizeWindowActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGSize) async throws -> DesktopActionResult<Void>
    {
        DesktopActionResult(outcome: .confirmedNoChange())
    }

    func setWindowBoundsActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        bounds _: CGRect) async throws -> DesktopActionResult<Void>
    {
        DesktopActionResult(outcome: .confirmedNoChange())
    }

    func recordedClose() async -> HandlerMutationWindowRecorder.Record? {
        await self.recorder.last
    }

    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}

    func focusWindowActionResult(target _: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        throw PeekabooError.commandFailed("Current focus must use the pinned result provider")
    }

    func focusWindowActionResult(
        target _: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        let identity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 456,
            capturedBounds: CGRect(x: 10, y: 20, width: 300, height: 200))
        guard identity.hasSameStableReceipt(as: expectedIdentity) else {
            throw PeekabooError.commandFailed("Bridge forwarded a different focus receipt")
        }
        guard let bounds = identity.capturedBounds else {
            throw PeekabooError.commandFailed("Focus fixture lacks bounds")
        }
        let exactWindow = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
        return UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .composite, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(3)),
            targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow))
    }

    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        if let readbackError {
            throw readbackError
        }
        return self.readback.map { [$0] } ?? []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}

private actor HandlerMutationWindowRecorder {
    struct Record: Sendable {
        let target: WindowTarget
        let identity: WindowMutationIdentity
        let allowForegroundFallback: Bool
    }

    private(set) var last: Record?

    func record(
        target: WindowTarget,
        identity: WindowMutationIdentity,
        allowForegroundFallback: Bool)
    {
        self.last = .init(
            target: target,
            identity: identity,
            allowForegroundFallback: allowForegroundFallback)
    }
}

private actor ReceiptlessCloseWindowService: WindowManagementServiceProtocol {
    private(set) var closeCount = 0

    func closeWindow(target _: WindowTarget) async throws {
        self.closeCount += 1
    }

    func closeWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        allowForegroundFallback _: Bool) async throws
    {
        self.closeCount += 1
    }

    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}
