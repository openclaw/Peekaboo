import ApplicationServices
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct ElementDetectionServiceDetachedObservationTests {
    @Test
    func `worker cooperative deadline returns structured evidence before the hard escape timer`() async throws {
        let request = RunnerState().makeRequest(timeoutSeconds: 1)
        let result = try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: request.processIdentifier,
            targetProcessStartIdentity: request.expectedProcessStartIdentity,
            seconds: request.timing.hardTimeoutSeconds)
        {
            try Self.resolutionFailure(
                request,
                delay: request.timing.cooperativeDeadlineSeconds + 0.02)
        }

        #expect(result.truncationInfo?.deadlineReached == true)
        #expect(result.truncationInfo?.incompleteAccessibilityRead == false)
    }

    @Test
    func `cooperative AX deadline returns partial evidence before the hard escape timer`() async throws {
        let request = RunnerState().makeRequest(timeoutSeconds: 1)
        let result = try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: request.processIdentifier,
            targetProcessStartIdentity: request.expectedProcessStartIdentity,
            seconds: request.timing.hardTimeoutSeconds)
        {
            Self.partialDeadlineResult(request)
        }

        #expect(result.truncationInfo?.deadlineReached == true)
        #expect(result.truncationInfo?.incompleteAccessibilityRead == false)
        #expect(result.elements.map(\.id) == [Self.partialElement.id])
    }

    @Test
    func `explicit timeout above twenty seconds reaches delayed worker and incomplete read is retried`() async throws {
        let cache = ElementDetectionCache()
        let cacheKey = try #require(cache.key(windowID: 42, processID: 123, allowWebFocus: false))
        let state = RunnerState()
        let service = ElementDetectionService(
            snapshotManager: nil,
            applicationService: nil,
            axTreeCache: cache,
            detachedAXObservationRunner: { request in
                state.requests.append(request)
                if state.requests.count == 1 {
                    return try await ElementDetectionTimeoutRunner.runDetached(
                        targetProcessIdentifier: request.processIdentifier,
                        targetProcessStartIdentity: request.expectedProcessStartIdentity,
                        seconds: request.timing.hardTimeoutSeconds)
                    {
                        try Self.resolutionFailure(
                            request,
                            delay: 0.02)
                    }
                }
                return Self.completeResult(request)
            })

        let first = try await service.cachedOrRunDetachedAXObservation(
            cacheKey: cacheKey,
            invalidatedThrough: nil,
            cachedContext: Self.cachedContext,
            makeRequest: { state.makeRequest(timeoutSeconds: 60) })

        #expect(first.usedCache == false)
        #expect(first.truncationInfo?.incompleteAccessibilityRead == true)
        #expect(first.truncationInfo?.deadlineReached == false)
        #expect(state.requests.map(\.timing.hardTimeoutSeconds) == [60])
        #expect(cache.result(for: cacheKey) == nil)

        let second = try await service.cachedOrRunDetachedAXObservation(
            cacheKey: cacheKey,
            invalidatedThrough: nil,
            cachedContext: Self.cachedContext,
            makeRequest: { state.makeRequest(timeoutSeconds: 60) })
        #expect(second.usedCache == false)
        #expect(second.elements.map(\.id) == ["elem_complete"])
        #expect(state.requests.map(\.timing.hardTimeoutSeconds) == [60, 60])
        #expect(cache.result(for: cacheKey)?.elements.map(\.id) == ["elem_complete"])

        let third = try await service.cachedOrRunDetachedAXObservation(
            cacheKey: cacheKey,
            invalidatedThrough: nil,
            cachedContext: Self.cachedContext,
            makeRequest: {
                Issue.record("A complete cached result must not rebuild or rerun the AX request")
                return state.makeRequest(timeoutSeconds: 60)
            })
        #expect(third.usedCache)
        #expect(third.elements.map(\.id) == ["elem_complete"])
        #expect(state.requests.count == 2)
        #expect(state.requestBuildCount == 2)
    }

    @Test
    func `resolve window failure after deadline is reported honestly and retried`() async throws {
        let cache = ElementDetectionCache()
        let cacheKey = try #require(cache.key(windowID: 42, processID: 123, allowWebFocus: false))
        let state = RunnerState()
        let service = ElementDetectionService(
            snapshotManager: nil,
            applicationService: nil,
            axTreeCache: cache,
            detachedAXObservationRunner: { request in
                state.requests.append(request)
                if state.requests.count == 1 {
                    return try Self.resolutionFailure(
                        request,
                        delay: 0.03)
                }
                return Self.completeResult(request)
            })

        let first = try await service.cachedOrRunDetachedAXObservation(
            cacheKey: cacheKey,
            invalidatedThrough: nil,
            cachedContext: Self.cachedContext,
            makeRequest: { state.makeRequest(timeoutSeconds: 0.01) })

        #expect(first.usedCache == false)
        #expect(first.truncationInfo?.deadlineReached == true)
        #expect(first.truncationInfo?.incompleteAccessibilityRead == false)
        #expect(cache.result(for: cacheKey) == nil)

        let second = try await service.cachedOrRunDetachedAXObservation(
            cacheKey: cacheKey,
            invalidatedThrough: nil,
            cachedContext: Self.cachedContext,
            makeRequest: { state.makeRequest(timeoutSeconds: 0.01) })
        #expect(second.usedCache == false)
        #expect(second.elements.map(\.id) == ["elem_complete"])

        let third = try await service.cachedOrRunDetachedAXObservation(
            cacheKey: cacheKey,
            invalidatedThrough: nil,
            cachedContext: Self.cachedContext,
            makeRequest: {
                Issue.record("A complete cached retry must not rebuild the AX request")
                return state.makeRequest(timeoutSeconds: 0.01)
            })
        #expect(third.usedCache)
        #expect(state.requests.count == 2)
        #expect(state.requestBuildCount == 2)
    }

    private static let cachedContext = CachedDetachedAXObservationContext(
        windowID: 42,
        windowTitle: "Cached fixture",
        windowBounds: CGRect(x: 10, y: 20, width: 800, height: 600),
        isDialog: false)

    private nonisolated static func resolutionFailure(
        _ request: DetachedAXObservationRequest,
        delay: TimeInterval) throws -> DetachedAXObservationResult
    {
        try DetachedAXObservationWorker.inspect(
            request,
            resolveWindow: { _, _, _ in
                Thread.sleep(forTimeInterval: delay)
                throw PeekabooError.windowNotFound(criteria: "injected AX window resolution failure")
            },
            exactWindowUnavailableResult: { request, deadlineReached in
                DetachedAXObservationResult(
                    elements: [],
                    windowID: request.windowID,
                    windowTitle: "Injected fixture",
                    windowBounds: request.expectedWindowBounds,
                    isDialog: false,
                    truncationInfo: DetachedAXObservationWorker.exactWindowResolutionFailureTruncation(
                        deadlineReached: deadlineReached))
            },
            validateIdentity: { _ in })
    }

    private nonisolated static func partialDeadlineResult(
        _ request: DetachedAXObservationRequest) -> DetachedAXObservationResult
    {
        Thread.sleep(forTimeInterval: request.timing.cooperativeDeadlineSeconds + 0.02)
        return DetachedAXObservationResult(
            elements: [self.partialElement],
            windowID: request.windowID,
            windowTitle: "Injected fixture",
            windowBounds: request.expectedWindowBounds,
            isDialog: false,
            truncationInfo: DetectionTruncationInfo(deadlineReached: true))
    }

    private nonisolated static let partialElement = DetectedElement(
        id: "elem_partial",
        type: .button,
        label: "Partial",
        value: nil,
        bounds: CGRect(x: 30, y: 40, width: 100, height: 30),
        isEnabled: true,
        isSelected: nil,
        attributes: [:])

    private nonisolated static func completeResult(
        _ request: DetachedAXObservationRequest) -> DetachedAXObservationResult
    {
        DetachedAXObservationResult(
            elements: [
                DetectedElement(
                    id: "elem_complete",
                    type: .textField,
                    label: "Complete",
                    value: "Complete",
                    bounds: CGRect(x: 30, y: 40, width: 200, height: 30),
                    isEnabled: true,
                    isSelected: nil,
                    attributes: [:]),
            ],
            windowID: request.windowID,
            windowTitle: "Injected fixture",
            windowBounds: request.expectedWindowBounds,
            isDialog: false,
            truncationInfo: nil)
    }
}

@MainActor
private final class RunnerState {
    var requests: [DetachedAXObservationRequest] = []
    var requestBuildCount = 0

    func makeRequest(timeoutSeconds: TimeInterval) -> DetachedAXObservationRequest {
        self.requestBuildCount += 1
        return DetachedAXObservationRequest(
            processIdentifier: 123,
            expectedProcessStartIdentity: 7,
            windowID: 42,
            windowTitle: "Fixture",
            expectedWindowBounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            windowMutationIdentity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 123,
                ownerProcessStartIdentity: 7),
            includeMenuBarElements: false,
            appIsActive: false,
            traversalBudget: AXTraversalBudget(),
            timing: DetachedAXObservationTiming(hardTimeoutSeconds: timeoutSeconds))
    }
}
