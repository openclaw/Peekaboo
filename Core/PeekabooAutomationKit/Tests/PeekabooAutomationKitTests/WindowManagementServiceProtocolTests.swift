import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct WindowManagementServiceProtocolTests {
    @Test
    func `identity defaults fail closed without dispatching legacy numeric overloads`() async {
        let double = LegacyOnlyWindowManagementService()
        let service: any WindowManagementServiceProtocol = double
        let identity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: 420,
            ownerProcessStartIdentity: 9001)
        let operations: [@Sendable () async throws -> Void] = [
            { try await service.closeWindow(
                target: .windowId(77),
                expectedIdentity: identity,
                allowForegroundFallback: false) },
            { try await service.minimizeWindow(target: .windowId(77), expectedIdentity: identity) },
            { try await service.restoreWindow(target: .windowId(77), expectedIdentity: identity) },
            { try await service.maximizeWindow(target: .windowId(77), expectedIdentity: identity) },
            { try await service.moveWindow(target: .windowId(77), expectedIdentity: identity, to: .zero) },
            { try await service.resizeWindow(target: .windowId(77), expectedIdentity: identity, to: .zero) },
            { try await service.setWindowBounds(target: .windowId(77), expectedIdentity: identity, bounds: .zero) },
        ]

        for operation in operations {
            do {
                try await operation()
                Issue.record("Expected an identity-unaware service to reject the pinned mutation")
            } catch let PeekabooError.serviceUnavailable(message) {
                #expect(message.contains("process-generation-pinned"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }

        #expect(await double.legacyDispatchCount == 0)
    }
}

private actor LegacyOnlyWindowManagementService: WindowManagementServiceProtocol {
    private(set) var legacyDispatchCount = 0

    func closeWindow(target _: WindowTarget) async throws {
        self.legacyDispatchCount += 1
    }

    func minimizeWindow(target _: WindowTarget) async throws {
        self.legacyDispatchCount += 1
    }

    func maximizeWindow(target _: WindowTarget) async throws {
        self.legacyDispatchCount += 1
    }

    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {
        self.legacyDispatchCount += 1
    }

    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {
        self.legacyDispatchCount += 1
    }

    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {
        self.legacyDispatchCount += 1
    }

    func focusWindow(target _: WindowTarget) async throws {}

    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}
