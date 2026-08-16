import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct WindowRoutedPointerVariantTests {
    private struct ClickSequenceCase {
        let button: MouseButton
        let count: Int
        let types: [CGEventType]
        let states: [Int64]
        let buttonNumbers: [Int64]
        let unitCount: Int
    }

    @Test
    @MainActor
    func `middle and triple clicks emit canonical exact-window event sequences`() async throws {
        let cases: [ClickSequenceCase] = [
            .init(
                button: .middle,
                count: 1,
                types: [.mouseMoved, .otherMouseDown, .otherMouseUp],
                states: [0, 1, 1],
                buttonNumbers: [0, 2, 2],
                unitCount: 3),
            .init(
                button: .left,
                count: 3,
                types: [
                    .mouseMoved,
                    .leftMouseDown,
                    .leftMouseUp,
                    .leftMouseDown,
                    .leftMouseUp,
                    .leftMouseDown,
                    .leftMouseUp,
                ],
                states: [0, 1, 1, 2, 2, 3, 3],
                buttonNumbers: [0, 0, 0, 0, 0, 0, 0],
                unitCount: 7),
        ]
        let receipt = Self.receipt()

        for testCase in cases {
            var specifications: [WindowRoutedPointerDriver.EventSpecification] = []
            var posted = 0
            let driver = WindowRoutedPointerDriver(
                hasPostEventAccess: { true },
                resolveRoute: { _, _, _ in receipt },
                routeIsCurrent: { _ in true },
                makeEvent: { specification, point in
                    specifications.append(specification)
                    return CGEvent(
                        mouseEventSource: nil,
                        mouseType: specification.type,
                        mouseCursorPosition: point,
                        mouseButton: specification.button)
                },
                stampWindowLocation: { _, _ in true },
                postSkyLight: { _, _ in true },
                postPublic: { _, _ in posted += 1 },
                resolveTransport: { _ in .publicCGEvent },
                sleep: { _ in })

            let outcome = try await driver.click(
                at: receipt.screenPoint,
                button: testCase.button,
                count: testCase.count,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID),
                expectedWindowIdentity: receipt.identity,
                expectedWindowBounds: receipt.bounds)

            #expect(specifications.map(\.type) == testCase.types)
            #expect(specifications.map(\.clickState) == testCase.states)
            #expect(specifications.map(\.buttonNumber) == testCase.buttonNumbers)
            if testCase.button == .middle {
                #expect(specifications.map(\.button) == [.left, .center, .center])
            }
            #expect(posted == testCase.unitCount)
            #expect(outcome.dispatchState.unitCount?.rawValue == testCase.unitCount)
            #expect(outcome.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
            #expect(outcome.effect == .unverifiable)
        }
    }

    @Test
    @MainActor
    func `middle and triple routes fail closed before posting on permission layer and bounds errors`() async {
        enum FailureCase: CaseIterable { case permission, layer, bounds }
        let base = Self.receipt()

        for failure in FailureCase.allCases {
            var posted = 0
            let receipt = switch failure {
            case .permission, .bounds: base
            case .layer:
                WindowRoutedPointerDriver.RouteReceipt(
                    identity: base.identity,
                    bounds: base.bounds,
                    screenPoint: base.screenPoint,
                    windowLayer: Int(CGWindowLevelForKey(.floatingWindow)))
            }
            let point = failure == .bounds
                ? CGPoint(x: receipt.bounds.maxX + 1, y: receipt.bounds.maxY + 1)
                : receipt.screenPoint
            let driver = WindowRoutedPointerDriver(
                hasPostEventAccess: { failure != .permission },
                resolveRoute: { _, _, _ in receipt },
                routeIsCurrent: { _ in true },
                makeEvent: { specification, eventPoint in
                    CGEvent(
                        mouseEventSource: nil,
                        mouseType: specification.type,
                        mouseCursorPosition: eventPoint,
                        mouseButton: specification.button)
                },
                stampWindowLocation: { _, _ in true },
                postSkyLight: { _, _ in posted += 1; return true },
                postPublic: { _, _ in posted += 1 },
                resolveTransport: { _ in .publicCGEvent },
                sleep: { _ in })

            await #expect(throws: (any Error).self) {
                _ = try await driver.click(
                    at: point,
                    button: failure == .permission ? .middle : .left,
                    count: failure == .permission ? 1 : 3,
                    targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                    targetWindowID: CGWindowID(receipt.identity.windowID),
                    expectedWindowIdentity: receipt.identity,
                    expectedWindowBounds: receipt.bounds)
            }
            #expect(posted == 0)
        }
    }

    @Test
    @MainActor
    func `triple click route drift preserves exact emitted prefix as indeterminate`() async {
        var validations = 0
        var posted = 0
        let receipt = Self.receipt()
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { _ in
                validations += 1
                return validations <= 3
            },
            makeEvent: { specification, point in
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: specification.type,
                    mouseCursorPosition: point,
                    mouseButton: specification.button)
            },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in true },
            postPublic: { _, _ in posted += 1 },
            resolveTransport: { _ in .publicCGEvent },
            sleep: { _ in })

        do {
            _ = try await driver.click(
                at: receipt.screenPoint,
                button: .left,
                count: 3,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID))
            Issue.record("Expected post-dispatch route drift")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 3)
            #expect(!error.retrySafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(posted == 3)
    }

    private static func receipt() -> WindowRoutedPointerDriver.RouteReceipt {
        WindowRoutedPointerDriver.RouteReceipt(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 9001),
            bounds: CGRect(x: 100, y: 200, width: 400, height: 300),
            screenPoint: CGPoint(x: 120, y: 230))
    }
}
