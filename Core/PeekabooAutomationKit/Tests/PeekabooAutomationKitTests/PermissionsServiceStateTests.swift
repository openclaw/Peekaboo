import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct PermissionsServiceStateTests {
    @Test
    func `passive live screen recording check does not probe before unlock`() async {
        var probeCount = 0
        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            shareableContentProbe: {
                probeCount += 1
            })
        let service = self.makeService(screenRecordingEvaluator: checker)

        #expect(await service.checkScreenRecordingPermissionLive() == false)
        #expect(probeCount == 0)
    }

    @Test
    func `forced live screen recording check unlocks subsequent passive probes`() async {
        var probeCount = 0
        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            shareableContentProbe: {
                probeCount += 1
                throw UnexpectedProbeError()
            })
        let service = self.makeService(screenRecordingEvaluator: checker)

        #expect(await service.checkScreenRecordingPermissionLive(forceProbe: true) == false)
        #expect(probeCount == 1)

        #expect(await service.checkScreenRecordingPermissionLive() == false)
        #expect(probeCount == 2)
    }

    @Test
    func `interactive screen recording request unlocks subsequent passive probe`() async {
        var probeCount = 0
        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            shareableContentProbe: {
                probeCount += 1
                throw UnexpectedProbeError()
            })
        let service = self.makeService(
            screenRecordingRequest: { false },
            screenRecordingEvaluator: checker)

        #expect(service.requestScreenRecordingPermission(interactive: true) == false)
        #expect(await service.checkScreenRecordingPermissionLive() == false)
        #expect(probeCount == 1)
    }

    @Test
    func `forced observable check authorizes when preflight fails but probe succeeds`() async {
        var probeCount = 0
        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            shareableContentProbe: {
                probeCount += 1
            })
        let service = self.makeService(screenRecordingEvaluator: checker)
        let observable = ObservablePermissionsService(core: service)

        await observable.checkPermissions(
            includeOptionalPermissions: false,
            forceScreenRecordingProbe: true)

        #expect(observable.screenRecordingStatus == .authorized)
        #expect(probeCount == 1)
    }

    @Test
    func `request authorization stays sticky across cached false preflights`() async {
        var screenRequestCount = 0
        var postEventRequestCount = 0
        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            shareableContentProbe: {
                Issue.record("Sticky request authorization should bypass the live probe")
                throw UnexpectedProbeError()
            })
        let service = self.makeService(
            screenRecordingRequest: {
                screenRequestCount += 1
                return true
            },
            screenRecordingEvaluator: checker,
            postEventRequest: {
                postEventRequestCount += 1
                return true
            })

        #expect(service.requestScreenRecordingPermission())
        #expect(service.checkScreenRecordingPermission())
        #expect(service.requestPostEventPermission())
        #expect(service.checkPostEventPermission())

        let observable = ObservablePermissionsService(core: service)
        await observable.checkPermissions(
            includeOptionalPermissions: true,
            forceScreenRecordingProbe: false)

        #expect(observable.screenRecordingStatus == .authorized)
        #expect(observable.postEventStatus == .authorized)
        #expect(screenRequestCount == 1)
        #expect(postEventRequestCount == 1)
    }

    @Test
    func `successful screen recording preflight skips probe`() async {
        var probeCount = 0
        let checker = ScreenRecordingPermissionChecker(
            preflight: { true },
            shareableContentProbe: {
                probeCount += 1
            })
        let service = self.makeService(screenRecordingEvaluator: checker)

        #expect(await service.checkScreenRecordingPermissionLive(forceProbe: true))
        #expect(probeCount == 0)
    }

    @Test
    func `forced live screen recording check bypasses the probe rate limiter`() async {
        var probeCount = 0
        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            shareableContentProbe: {
                probeCount += 1
                throw UnexpectedProbeError()
            })
        let service = self.makeService(
            screenRecordingEvaluator: checker,
            probeMinimumInterval: .seconds(3600))

        #expect(await service.checkScreenRecordingPermissionLive(forceProbe: true) == false)
        #expect(probeCount == 1)

        // Passive polls are rate-limited...
        #expect(await service.checkScreenRecordingPermissionLive() == false)
        #expect(probeCount == 1)

        // ...but an explicit Refresh probes again immediately.
        #expect(await service.checkScreenRecordingPermissionLive(forceProbe: true) == false)
        #expect(probeCount == 2)
    }

    @Test
    func `forced check reprobes after joining a stale in-flight probe`() async {
        var probeCount = 0
        var releaseFirstProbe: CheckedContinuation<Void, Never>?
        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            shareableContentProbe: {
                probeCount += 1
                if probeCount == 1 {
                    await withCheckedContinuation { releaseFirstProbe = $0 }
                    throw UnexpectedProbeError()
                }
            })
        let service = self.makeService(
            screenRecordingEvaluator: checker,
            probeMinimumInterval: .seconds(3600))

        let first = Task { await service.checkScreenRecordingPermissionLive(forceProbe: true) }
        while probeCount == 0 {
            await Task.yield()
        }

        let second = Task { await service.checkScreenRecordingPermissionLive(forceProbe: true) }
        for _ in 0..<10 {
            await Task.yield()
        }
        releaseFirstProbe?.resume()

        // The first probe was stale (denied); the forced second caller must run a fresh probe
        // instead of re-joining the completed stale one. Waiter resume order after the release
        // is up to the runtime, so this pins the contract for whichever order executes; the
        // clear-if-same bookkeeping in evaluateScreenRecordingAuthorization covers the other.
        #expect(await first.value == false)
        #expect(await second.value == true)
        #expect(probeCount == 2)
    }

    private func makeService(
        screenRecordingRequest: @escaping @MainActor @Sendable () -> Bool = { false },
        screenRecordingEvaluator: ScreenRecordingPermissionChecker,
        postEventRequest: @escaping @MainActor @Sendable () -> Bool = { false },
        probeMinimumInterval: Duration = .zero) -> PermissionsService
    {
        PermissionsService(
            dependencies: PermissionsService.Dependencies(
                screenRecordingPreflight: { false },
                screenRecordingRequest: screenRecordingRequest,
                screenRecordingEvaluator: screenRecordingEvaluator,
                postEventPreflight: { false },
                postEventRequest: postEventRequest),
            authorizationState: PermissionsService.AuthorizationState(),
            screenRecordingProbeMinimumInterval: probeMinimumInterval,
            loggingService: MockLoggingService())
    }

    private struct UnexpectedProbeError: Error {}
}
