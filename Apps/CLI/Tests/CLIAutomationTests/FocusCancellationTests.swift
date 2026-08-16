import CoreGraphics
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct FocusCancellationTests {
    @Test
    func `Cancellation during fallback activation propagates after the service returns`() async {
        let bundleIdentifier = "com.example.focus-cancellation"
        let application = ServiceApplicationInfo(
            processIdentifier: 4242,
            processStartIdentity: 9001,
            bundleIdentifier: bundleIdentifier,
            name: "Focus Cancellation"
        )
        let applications = StubApplicationService(applications: [application])
        applications.activateApplicationHandler = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let services = TestServicesFactory.makePeekabooServices(applications: applications)
        let options = FocusOptions(
            autoFocus: true,
            focusTimeout: nil,
            focusRetryCount: nil,
            spaceSwitch: false,
            bringToCurrentSpace: false
        )
        let task = Task { @MainActor in
            try await ensureFocused(
                applicationName: bundleIdentifier,
                options: options,
                services: services
            )
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(applications.activateCalls == ["PID:4242"])
    }

    @Test
    func `Cancellation after focus completion preserves canonical result and target`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds
        )
        let window = ServiceWindowInfo(
            windowID: identity.windowID,
            title: "Fixture",
            bounds: bounds,
            mutationIdentity: identity
        )
        let services = TestServicesFactory.makePeekabooServices(
            windows: StubWindowService(windowsByApp: ["Fixture": [window]])
        )
        let expectedOutcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let options = FocusOptions(
            autoFocus: true,
            focusTimeout: nil,
            focusRetryCount: nil,
            spaceSwitch: false,
            bringToCurrentSpace: false
        )

        let task = Task { @MainActor in
            try await ensureFocused(
                windowID: CGWindowID(identity.windowID),
                options: options,
                services: services,
                focusResultProvider: { _, _, receivedIdentity in
                    #expect(receivedIdentity.hasSameStableReceipt(as: identity))
                    withUnsafeCurrentTask { $0?.cancel() }
                    return expectedOutcome
                }
            )
        }

        let result = try await task.value
        #expect(result.outcome == expectedOutcome)
        #expect(result.targetIdentity?.exactWindow?.identity.hasSameStableReceipt(as: identity) == true)
    }

    @Test
    func `Local focus fallback forwards original preflight receipt`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 88,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds
        )
        let window = ServiceWindowInfo(
            windowID: identity.windowID,
            title: "Fallback",
            bounds: bounds,
            mutationIdentity: identity
        )
        let windows = PinnedFallbackWindowService(windowsByApp: ["Fixture": [window]])
        let services = TestServicesFactory.makePeekabooServices(windows: windows)
        let options = FocusOptions(
            autoFocus: true,
            focusTimeout: nil,
            focusRetryCount: nil,
            spaceSwitch: false,
            bringToCurrentSpace: false
        )

        let result = try await ensureFocused(
            windowID: CGWindowID(identity.windowID),
            options: options,
            services: services,
            focusResultProvider: { windowID, _, receivedIdentity in
                #expect(Int(windowID) == identity.windowID)
                #expect(receivedIdentity.hasSameStableReceipt(as: identity))
                throw FocusError.axElementNotFound(windowID)
            }
        )

        #expect(windows.unpinnedFocusCallCount == 0)
        #expect(windows.pinnedFocusIdentities.count == 1)
        #expect(windows.pinnedFocusIdentities[0].hasSameStableReceipt(as: identity))
        #expect(result.targetIdentity?.exactWindow?.identity.hasSameStableReceipt(as: identity) == true)
    }

    @Test
    func `Explicit partial title focuses its sole matching window`() async throws {
        let matchingBounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let matchingIdentity = WindowMutationIdentity(
            windowID: 88,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 9001,
            capturedBounds: matchingBounds
        )
        let matchingWindow = ServiceWindowInfo(
            windowID: matchingIdentity.windowID,
            title: "Quarterly Document",
            bounds: matchingBounds,
            mutationIdentity: matchingIdentity
        )
        let otherBounds = CGRect(x: 30, y: 40, width: 300, height: 200)
        let otherWindow = ServiceWindowInfo(
            windowID: 89,
            title: "Inbox",
            bounds: otherBounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: 89,
                ownerProcessIdentifier: 4242,
                ownerProcessStartIdentity: 9001,
                capturedBounds: otherBounds
            )
        )
        let services = TestServicesFactory.makePeekabooServices(
            windows: StubWindowService(windowsByApp: ["Fixture": [otherWindow, matchingWindow]])
        )
        let expectedOutcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let options = FocusOptions(
            autoFocus: true,
            focusTimeout: nil,
            focusRetryCount: nil,
            spaceSwitch: false,
            bringToCurrentSpace: false
        )

        let result = try await ensureFocused(
            applicationName: "Fixture",
            windowTitle: "Document",
            options: options,
            services: services,
            focusResultProvider: { windowID, _, receivedIdentity in
                #expect(windowID == CGWindowID(matchingIdentity.windowID))
                #expect(receivedIdentity.hasSameStableReceipt(as: matchingIdentity))
                return expectedOutcome
            }
        )

        #expect(result.outcome == expectedOutcome)
        #expect(result.targetIdentity?.exactWindow?.identity.hasSameStableReceipt(as: matchingIdentity) == true)
    }
}

@MainActor
private final class PinnedFallbackWindowService: StubWindowService,
WindowManagementPinnedFocusActionResultProviding {
    private(set) var unpinnedFocusCallCount = 0
    private(set) var pinnedFocusIdentities: [WindowMutationIdentity] = []

    @MainActor
    func focusWindowActionResult(target _: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        self.unpinnedFocusCallCount += 1
        throw PeekabooError.commandFailed("Fallback must retain the preflight focus receipt")
    }

    @MainActor
    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        self.pinnedFocusIdentities.append(expectedIdentity)
        guard case let .windowId(windowID) = target,
              windowID == expectedIdentity.windowID,
              let bounds = expectedIdentity.capturedBounds
        else {
            throw PeekabooError.windowNotFound(criteria: target.description)
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .composite, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetIdentity: DesktopTargetIdentity(
                exactWindow: UIAutomationTarget.ExactWindow(
                    identity: expectedIdentity,
                    bounds: bounds
                )
            )
        )
    }
}
