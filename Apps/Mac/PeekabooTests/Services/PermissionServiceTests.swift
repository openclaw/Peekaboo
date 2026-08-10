import Foundation
import Testing
@testable import Peekaboo
@testable import PeekabooCore

@Suite(.tags(.services, .unit))
@MainActor
struct PermissionsTests {
    class MockObservablePermissionsService: ObservablePermissionsServiceProtocol {
        var screenRecordingStatus: ObservablePermissionsService.PermissionState = .notDetermined
        var accessibilityStatus: ObservablePermissionsService.PermissionState = .notDetermined
        var appleScriptStatus: ObservablePermissionsService.PermissionState = .notDetermined
        var postEventStatus: ObservablePermissionsService.PermissionState = .notDetermined

        private(set) var checkPermissionsCallCount = 0
        private(set) var forceScreenRecordingProbeValues: [Bool] = []
        private(set) var requestPostEventCallCount = 0
        var hasAllPermissions: Bool {
            self.screenRecordingStatus == .authorized && self.accessibilityStatus == .authorized
        }

        func checkPermissions(includeOptionalPermissions: Bool, forceScreenRecordingProbe: Bool) async {
            self.checkPermissionsCallCount += 1
            self.forceScreenRecordingProbeValues.append(forceScreenRecordingProbe)
            self.screenRecordingStatus = .denied
            self.accessibilityStatus = .denied
        }

        func requestScreenRecording() async {}
        func requestAccessibility() async {}
        func requestAppleScript() async {}
        func requestPostEvent() async {
            self.requestPostEventCallCount += 1
        }
    }

    let permissions: Permissions
    let mockPermissionsService: MockObservablePermissionsService

    init() {
        let mockService = MockObservablePermissionsService()
        self.mockPermissionsService = mockService
        self.permissions = Permissions(permissionsService: mockService)
    }

    @Test
    func `Service initializes with unknown permissions`() {
        // Initial state should be unknown since we haven't checked yet
        #expect(self.permissions.screenRecordingStatus == .notDetermined)
        #expect(self.permissions.accessibilityStatus == .notDetermined)
        #expect(PermissionCapability.allCases == [.screenRecording, .accessibility, .postEvent])
    }

    @Test
    func `Has all permissions when both are authorized`() {
        self.mockPermissionsService.screenRecordingStatus = .authorized
        self.mockPermissionsService.accessibilityStatus = .authorized
        #expect(self.permissions.hasAllPermissions == true)

        // Test various combinations
        self.mockPermissionsService.screenRecordingStatus = .denied
        #expect(self.permissions.hasAllPermissions == false)

        self.mockPermissionsService.screenRecordingStatus = .authorized
        self.mockPermissionsService.accessibilityStatus = .denied
        #expect(self.permissions.hasAllPermissions == false)

        self.mockPermissionsService.screenRecordingStatus = .notDetermined
        self.mockPermissionsService.accessibilityStatus = .authorized
        #expect(self.permissions.hasAllPermissions == false)
    }

    @Test(arguments: [
        (
            ObservablePermissionsService.PermissionState.authorized,
            ObservablePermissionsService.PermissionState.authorized,
            true),
        (
            ObservablePermissionsService.PermissionState.authorized,
            ObservablePermissionsService.PermissionState.denied,
            false),
        (
            ObservablePermissionsService.PermissionState.denied,
            ObservablePermissionsService.PermissionState.authorized,
            false),
        (
            ObservablePermissionsService.PermissionState.denied,
            ObservablePermissionsService.PermissionState.denied,
            false),
        (
            ObservablePermissionsService.PermissionState.notDetermined,
            ObservablePermissionsService.PermissionState.authorized,
            false),
        (
            ObservablePermissionsService.PermissionState.authorized,
            ObservablePermissionsService.PermissionState.notDetermined,
            false),
        (
            ObservablePermissionsService.PermissionState.notDetermined,
            ObservablePermissionsService.PermissionState.notDetermined,
            false)
    ])
    func `Permission status combinations`(
        screenRecording: ObservablePermissionsService.PermissionState,
        accessibility: ObservablePermissionsService.PermissionState,
        expectedHasAll: Bool)
    {
        self.mockPermissionsService.screenRecordingStatus = screenRecording
        self.mockPermissionsService.accessibilityStatus = accessibility
        #expect(self.permissions.hasAllPermissions == expectedHasAll)
    }

    @Test
    @MainActor
    func `Permission checking updates status`() async {
        // This test verifies the check method runs without crashing.
        await self.permissions.check()

        // The app-level wrapper always refreshes required permissions directly.
        #expect(self.permissions.screenRecordingStatus != .notDetermined)
        #expect(self.permissions.accessibilityStatus != .notDetermined)
        #expect(self.mockPermissionsService.forceScreenRecordingProbeValues == [false])
    }

    @Test
    @MainActor
    func `Permission refresh forces screen recording probe`() async {
        await self.permissions.refresh()

        #expect(self.mockPermissionsService.forceScreenRecordingProbeValues == [true])
    }

    @Test
    @MainActor
    func `Optional permission checks are throttled`() async {
        #expect(self.mockPermissionsService.checkPermissionsCallCount == 0)

        self.permissions.setIncludeOptionalPermissions(true)
        await self.permissions.check()
        #expect(self.mockPermissionsService.checkPermissionsCallCount == 1)

        // Subsequent checks within the optional interval should not call through again.
        await self.permissions.check()
        #expect(self.mockPermissionsService.checkPermissionsCallCount == 1)

        self.permissions.setIncludeOptionalPermissions(false)
        await self.permissions.check()
        #expect(self.mockPermissionsService.checkPermissionsCallCount == 1)
    }

    @Test
    @MainActor
    func `Event synthesizing request is forwarded to permission service`() async {
        await self.permissions.requestPostEvent()

        #expect(self.mockPermissionsService.requestPostEventCallCount == 1)
    }
}

@Suite(.tags(.services, .integration, .permissions))
@MainActor
struct PermissionsSystemTests {
    @Test
    @MainActor
    func `Request permissions opens system preferences`() async throws {
        let permissions = Permissions()

        // This test is mainly to ensure the method doesn't crash
        // We can't actually test if System Preferences opens in unit tests
        await permissions.requestScreenRecording()
        await permissions.requestAccessibility()
        await permissions.requestPostEvent()

        // Give a moment for any async operations
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // If we get here without crashing, the test passes
        #expect(Bool(true))
    }
}
