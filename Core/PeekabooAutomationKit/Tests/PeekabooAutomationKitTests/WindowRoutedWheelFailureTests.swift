import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct WindowRoutedWheelFailureTests {
    @Test(arguments: FailurePoint.allCases)
    private func `wheel failures before the first event retain typed no-dispatch semantics`(
        point: FailurePoint) async
    {
        let probe = Probe(failure: point)
        do {
            _ = try await probe.scroll()
            Issue.record("Expected a pre-dispatch wheel refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.refusalReason == point.refusalReason)
            #expect(failure.standardErrorCode == point.errorCode)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(probe.posts == 0)
    }

    @Test(arguments: [
        FailurePoint.revalidation, .visibility, .eventConstruction, .windowStamp, .transport,
    ])
    private func `wheel preparation failures after a prefix remain retry unsafe`(point: FailurePoint) async {
        let probe = Probe(failure: point, failureAfterPosts: 1)
        do {
            _ = try await probe.scroll()
            Issue.record("Expected an accepted-prefix wheel failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 1)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(probe.posts == 1)
    }

    @Test
    func `completed wheel dispatch retains its unsafe outcome when final validation fails`() async {
        let probe = Probe(failure: .revalidation, failureAfterPosts: 3)
        do {
            _ = try await probe.scroll()
            Issue.record("Expected completed wheel validation failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(probe.posts == 3)
    }

    @Test(arguments: [0, 1, 2])
    func `wheel cancellation distinguishes initial preparation from an accepted prefix`(stage: Int) async {
        let probe = Probe()
        probe.cancelDuringResolution = stage == 1
        probe.cancelAfterPosts = stage == 2 ? 1 : nil
        let task = Task { @MainActor in
            if stage == 0 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return try await probe.scroll()
        }
        do {
            _ = try await task.value
            Issue.record("Expected wheel cancellation")
        } catch let failure as DesktopActionFailure {
            if stage == 2 {
                #expect(failure.outcome.state == .partial)
                #expect(failure.outcome.dispatchState.unitCount?.rawValue == 1)
                #expect(failure.outcome.retrySafety == .unsafe)
            } else {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.refusalReason == .requestCancelled)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.retrySafety == .safe)
                #expect(failure.standardErrorCode == .cancelled)
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(probe.posts == (stage == 2 ? 1 : 0))
    }

    @Test
    func `already typed uncertain route failures are not relabeled as zero dispatch`() async {
        let expected = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Synthetic prior uncertain input")
        let probe = Probe()
        probe.resolutionError = expected
        do {
            _ = try await probe.scroll()
            Issue.record("Expected the original typed failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(probe.posts == 0)
    }

    @Test
    func `legacy uncertain input errors are not relabeled as zero dispatch`() async {
        let expected = InputDeliveryIndeterminateError(
            operation: .click,
            emittedUnitCount: 1,
            causeDescription: "Synthetic prior uncertain input")
        let probe = Probe()
        probe.resolutionError = expected
        do {
            _ = try await probe.scroll()
            Issue.record("Expected the original legacy failure")
        } catch let failure as InputDeliveryIndeterminateError {
            #expect(failure.emittedUnitCount == expected.emittedUnitCount)
            #expect(failure.causeDescription == expected.causeDescription)
            #expect(!failure.retrySafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(probe.posts == 0)
    }

    private enum FailurePoint: CaseIterable {
        case invalidTicks, permission, resolution, bounds, visibility, revalidation
        case eventConstruction, windowStamp, transport

        var refusalReason: DesktopActionOutcome.RefusalReason {
            switch self {
            case .invalidTicks: .invalidRequest
            case .permission: .permissionDenied
            case .resolution, .bounds, .visibility, .revalidation: .targetUnavailable
            case .eventConstruction, .windowStamp, .transport: .runtimeIncompatible
            }
        }

        var errorCode: StandardErrorCode {
            switch self {
            case .invalidTicks: .invalidInput
            case .permission: .eventSynthesizingPermissionDenied
            case .resolution, .bounds, .visibility, .revalidation: .snapshotStale
            case .eventConstruction, .windowStamp, .transport: .unknownError
            }
        }
    }

    @MainActor
    private final class Probe {
        let failure: FailurePoint?
        let failureAfterPosts: Int
        var posts = 0
        var resolutionError: (any Error)?
        var cancelDuringResolution = false
        var cancelAfterPosts: Int?

        init(failure: FailurePoint? = nil, failureAfterPosts: Int = 0) {
            self.failure = failure
            self.failureAfterPosts = failureAfterPosts
        }

        private func fails(at point: FailurePoint) -> Bool {
            self.failure == point && self.posts >= self.failureAfterPosts
        }

        private func recordPost() {
            self.posts += 1
            if self.posts == self.cancelAfterPosts {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        func scroll() async throws -> DesktopActionOutcome {
            let receipt = WindowRoutedPointerDriver.RouteReceipt(
                identity: .init(windowID: 7, ownerProcessIdentifier: 42, ownerProcessStartIdentity: 9001),
                bounds: CGRect(x: 100, y: 200, width: 400, height: 300),
                screenPoint: CGPoint(x: 120, y: 230))
            let driver = WindowRoutedPointerDriver(
                hasPostEventAccess: { !self.fails(at: .permission) },
                resolveRoute: { _, _, _ in
                    if let error = self.resolutionError {
                        throw error
                    }
                    if self.fails(at: .resolution) {
                        throw PeekabooError.snapshotStale("Cannot prove the exact background wheel route")
                    }
                    if self.cancelDuringResolution {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return receipt
                },
                routeIsCurrent: { _ in !self.fails(at: .revalidation) },
                makeScrollEvent: { _, _ in
                    guard !self.fails(at: .eventConstruction) else { return nil }
                    return CGEvent(
                        scrollWheelEvent2Source: nil,
                        units: .line,
                        wheelCount: 1,
                        wheel1: -1,
                        wheel2: 0,
                        wheel3: 0)
                },
                stampWindowLocation: { _, _ in !self.fails(at: .windowStamp) },
                postSkyLight: { _, _ in
                    guard !self.fails(at: .transport) else { return false }
                    self.recordPost()
                    return true
                },
                postPublic: { _, _ in self.recordPost() },
                resolveTransport: { _ in self.failure == .transport ? .skyLight : .publicCGEvent },
                applicationIsVisible: { _ in !self.fails(at: .visibility) },
                windowIsVisible: { _ in true },
                sleep: { _ in })
            let point = self.failure == .bounds
                ? CGPoint(x: receipt.bounds.maxX + 1, y: receipt.screenPoint.y) : receipt.screenPoint
            return try await driver.scroll(
                at: point,
                direction: .down,
                ticks: self.failure == .invalidTicks ? 0 : 3,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID),
                expectedWindowIdentity: receipt.identity,
                expectedWindowBounds: receipt.bounds)
        }
    }
}
