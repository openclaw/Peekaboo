import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct WindowRoutedPointerDriverTests {
    private enum PreparationFailure: CaseIterable {
        case eventConstruction
        case windowStamp

        var causeFragment: String {
            switch self {
            case .eventConstruction: "could not be constructed"
            case .windowStamp: "window-local point"
            }
        }
    }

    @Test
    @MainActor
    func `background wheel stamps exact route without pointer primer`() async throws {
        var directions: [PeekabooFoundation.ScrollDirection] = []
        var windowPoints: [CGPoint] = []
        var publicEvents: [CGEvent] = []
        var clickEventsConstructed = 0
        var validations = 0
        let receipt = Self.receipt()
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { _ in validations += 1; return true },
            makeEvent: { _, _ in clickEventsConstructed += 1; return nil },
            makeScrollEvent: { direction, point in
                directions.append(direction)
                let event = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .line,
                    wheelCount: 2,
                    wheel1: -1,
                    wheel2: 0,
                    wheel3: 0)
                event?.location = point
                return event
            },
            stampWindowLocation: { _, point in windowPoints.append(point); return true },
            postSkyLight: { _, _ in true },
            postPublic: { event, _ in publicEvents.append(event) },
            resolveTransport: { _ in .publicCGEvent },
            applicationIsVisible: { _ in true },
            windowIsVisible: { _ in true },
            sleep: { _ in },
            clickGroupIdentifier: { 992 })

        let outcome = try await driver.scroll(
            at: receipt.screenPoint,
            direction: .down,
            ticks: 3,
            targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
            targetWindowID: CGWindowID(receipt.identity.windowID),
            expectedWindowIdentity: receipt.identity,
            expectedWindowBounds: receipt.bounds)

        #expect(outcome.state == .dispatchedUnverified)
        #expect(outcome.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
        #expect(outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(outcome.retrySafety == .unsafe)
        #expect(directions == [.down, .down, .down])
        #expect(windowPoints == Array(repeating: receipt.windowPoint, count: 3))
        #expect(clickEventsConstructed == 0)
        #expect(publicEvents.count == 3)
        #expect(validations == 4)
        for event in publicEvents {
            #expect(event.getIntegerValueField(.eventTargetUnixProcessID) == 42)
            #expect(try event.getIntegerValueField(#require(CGEventField(rawValue: 51))) == 7)
            #expect(try event.getIntegerValueField(#require(CGEventField(rawValue: 58))) == 992)
        }
    }

    @Test
    @MainActor
    func `background wheel route drift after dispatch is retry unsafe`() async {
        var validations = 0
        var posts = 0
        let receipt = Self.receipt()
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { _ in validations += 1; return validations == 1 },
            makeScrollEvent: { _, _ in
                CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .line,
                    wheelCount: 1,
                    wheel1: -1,
                    wheel2: 0,
                    wheel3: 0)
            },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in true },
            postPublic: { _, _ in posts += 1 },
            resolveTransport: { _ in .publicCGEvent },
            applicationIsVisible: { _ in true },
            windowIsVisible: { _ in true },
            sleep: { _ in })

        do {
            _ = try await driver.scroll(
                at: receipt.screenPoint,
                direction: .down,
                ticks: 3,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID),
                expectedWindowIdentity: receipt.identity,
                expectedWindowBounds: receipt.bounds)
            Issue.record("Expected post-dispatch route drift")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 1)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.mutationDispatched)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(posts == 1)
        #expect(validations == 2)
    }

    @Test
    @MainActor
    func `background wheel refuses an initially hidden app before dispatch`() async {
        var posts = 0
        let receipt = Self.receipt()
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { _ in true },
            makeScrollEvent: { _, _ in
                CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .line,
                    wheelCount: 1,
                    wheel1: -1,
                    wheel2: 0,
                    wheel3: 0)
            },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in true },
            postPublic: { _, _ in posts += 1 },
            resolveTransport: { _ in .publicCGEvent },
            applicationIsVisible: { _ in false },
            windowIsVisible: { _ in true },
            sleep: { _ in })

        await #expect(throws: PeekabooError.self) {
            _ = try await driver.scroll(
                at: receipt.screenPoint,
                direction: .down,
                ticks: 2,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID),
                expectedWindowIdentity: receipt.identity,
                expectedWindowBounds: receipt.bounds)
        }
        #expect(posts == 0)
    }

    @Test
    @MainActor
    func `background wheel visibility loss after one tick is retry unsafe`() async {
        var visibilityChecks = 0
        var posts = 0
        let receipt = Self.receipt()
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { _ in true },
            makeScrollEvent: { _, _ in
                CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .line,
                    wheelCount: 1,
                    wheel1: -1,
                    wheel2: 0,
                    wheel3: 0)
            },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in true },
            postPublic: { _, _ in posts += 1 },
            resolveTransport: { _ in .publicCGEvent },
            applicationIsVisible: { _ in true },
            windowIsVisible: { _ in
                visibilityChecks += 1
                return visibilityChecks <= 2
            },
            sleep: { _ in })

        do {
            _ = try await driver.scroll(
                at: receipt.screenPoint,
                direction: .down,
                ticks: 3,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID),
                expectedWindowIdentity: receipt.identity,
                expectedWindowBounds: receipt.bounds)
            Issue.record("Expected post-dispatch visibility loss")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 1)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.escalation == .recoverSideEffect)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(posts == 1)
        #expect(visibilityChecks == 3)
    }

    @Test
    @MainActor
    func `right click stamps exact window route and reports unverifiable dispatch`() async throws {
        var specifications: [WindowRoutedPointerDriver.EventSpecification] = []
        var windowPoints: [CGPoint] = []
        var publicEvents: [CGEvent] = []
        var skyLightPosts = 0
        var validations = 0
        let receipt = Self.receipt()
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { _ in
                validations += 1
                return true
            },
            makeEvent: { specification, point in
                specifications.append(specification)
                return CGEvent(
                    mouseEventSource: nil,
                    mouseType: specification.type,
                    mouseCursorPosition: point,
                    mouseButton: specification.button)
            },
            stampWindowLocation: { _, point in
                windowPoints.append(point)
                return true
            },
            postSkyLight: { _, _ in
                skyLightPosts += 1
                return true
            },
            postPublic: { event, _ in publicEvents.append(event) },
            resolveTransport: { _ in .publicCGEvent },
            sleep: { _ in },
            clickGroupIdentifier: { 991 })

        let outcome = try await driver.click(
            at: receipt.screenPoint,
            button: .right,
            count: 1,
            targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
            targetWindowID: CGWindowID(receipt.identity.windowID))

        #expect(outcome.state == .dispatchedUnverified)
        #expect(outcome.evidence == .deliveryAccepted)
        #expect(outcome.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
        #expect(outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(!outcome.isConfirmed)
        #expect(specifications.map(\.type) == [.mouseMoved, .rightMouseDown, .rightMouseUp])
        #expect(specifications.map(\.clickState) == [0, 1, 1])
        #expect(specifications.map(\.buttonNumber) == [0, 1, 1])
        #expect(windowPoints == Array(repeating: CGPoint(x: 20, y: 30), count: 3))
        #expect(skyLightPosts == 0)
        #expect(publicEvents.count == 3)
        #expect(validations == 4)
        for event in publicEvents {
            #expect(event.getIntegerValueField(.eventTargetUnixProcessID) == 42)
            #expect(try event.getIntegerValueField(#require(CGEventField(rawValue: 51))) == 7)
            #expect(try event.getIntegerValueField(#require(CGEventField(rawValue: 58))) == 991)
            #expect(try event.getIntegerValueField(#require(CGEventField(rawValue: 91))) == 7)
            #expect(try event.getIntegerValueField(#require(CGEventField(rawValue: 92))) == 7)
        }
    }

    @Test
    @MainActor
    func `final route drift retains exact dispatched event evidence`() async {
        var validations = 0
        var posted = 0
        let receipt = Self.receipt()
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { _ in
                validations += 1
                return validations < 4
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
                button: .right,
                count: 1,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID))
            Issue.record("Expected final route drift after all pointer events were posted")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.causeDescription?.contains("changed") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(posted == 3)
        #expect(validations == 4)
    }

    @Test
    @MainActor
    func `SkyLight target posts each logical event once without public duplication`() async throws {
        var skyLightPosts = 0
        var publicPosts = 0
        let receipt = Self.receipt()
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { _ in true },
            makeEvent: { specification, point in
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: specification.type,
                    mouseCursorPosition: point,
                    mouseButton: specification.button)
            },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in skyLightPosts += 1; return true },
            postPublic: { _, _ in publicPosts += 1 },
            resolveTransport: { _ in .skyLight },
            sleep: { _ in })

        let outcome = try await driver.click(
            at: receipt.screenPoint,
            button: .left,
            count: 2,
            targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
            targetWindowID: CGWindowID(receipt.identity.windowID))

        #expect(outcome.state == .dispatchedUnverified)
        #expect(outcome.evidence == .deliveryAccepted)
        #expect(outcome.dispatchState.unitCount?.rawValue == 5)
        #expect(!outcome.isConfirmed)
        #expect(skyLightPosts == 5)
        #expect(publicPosts == 0)
    }

    @Test
    @MainActor
    func `second double click preparation failures preserve first pair emitted count`() async {
        for failure in PreparationFailure.allCases {
            var eventConstructionCount = 0
            var stampCount = 0
            var postedTypes: [CGEventType] = []
            let receipt = Self.receipt()
            let driver = WindowRoutedPointerDriver(
                hasPostEventAccess: { true },
                resolveRoute: { _, _, _ in receipt },
                routeIsCurrent: { _ in true },
                makeEvent: { specification, point in
                    eventConstructionCount += 1
                    if failure == .eventConstruction, eventConstructionCount == 4 {
                        return nil
                    }
                    return CGEvent(
                        mouseEventSource: nil,
                        mouseType: specification.type,
                        mouseCursorPosition: point,
                        mouseButton: specification.button)
                },
                stampWindowLocation: { _, _ in
                    stampCount += 1
                    return !(failure == .windowStamp && stampCount == 4)
                },
                postSkyLight: { _, _ in true },
                postPublic: { event, _ in postedTypes.append(event.type) },
                resolveTransport: { _ in .publicCGEvent },
                sleep: { _ in })

            do {
                _ = try await driver.click(
                    at: receipt.screenPoint,
                    button: .left,
                    count: 2,
                    targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                    targetWindowID: CGWindowID(receipt.identity.windowID))
                Issue.record("Expected second-pair \(failure) failure to be indeterminate")
            } catch let error as InputDeliveryIndeterminateError {
                #expect(error.operation == .click)
                #expect(error.emittedUnitCount == 3)
                #expect(!error.retrySafe)
                #expect(error.causeDescription?.contains(failure.causeFragment) == true)
            } catch {
                Issue.record("Unexpected \(failure) error: \(error)")
            }
            #expect(postedTypes == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        }
    }

    @Test
    @MainActor
    func `pre-dispatch preparation failures remain ordinary`() async {
        for failure in PreparationFailure.allCases {
            var posted = 0
            let receipt = Self.receipt()
            let driver = WindowRoutedPointerDriver(
                hasPostEventAccess: { true },
                resolveRoute: { _, _, _ in receipt },
                routeIsCurrent: { _ in true },
                makeEvent: { specification, point in
                    guard failure != .eventConstruction else { return nil }
                    return CGEvent(
                        mouseEventSource: nil,
                        mouseType: specification.type,
                        mouseCursorPosition: point,
                        mouseButton: specification.button)
                },
                stampWindowLocation: { _, _ in failure != .windowStamp },
                postSkyLight: { _, _ in posted += 1; return true },
                postPublic: { _, _ in posted += 1 },
                resolveTransport: { _ in .publicCGEvent },
                sleep: { _ in })

            do {
                _ = try await driver.click(
                    at: receipt.screenPoint,
                    button: .left,
                    count: 2,
                    targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                    targetWindowID: CGWindowID(receipt.identity.windowID))
                Issue.record("Expected initial \(failure) failure")
            } catch is InputDeliveryIndeterminateError {
                Issue.record("Pre-dispatch \(failure) failure must remain ordinary")
            } catch {
                // Expected ordinary Peekaboo error before any routed event was posted.
            }
            #expect(posted == 0)
        }
    }

    @Test
    @MainActor
    func `wrong owner or changed window receipt is refused before posting`() async {
        var posted = 0
        let requested = Self.receipt()
        let wrongOwner = WindowRoutedPointerDriver.RouteReceipt(
            identity: WindowMutationIdentity(
                windowID: requested.identity.windowID,
                ownerProcessIdentifier: requested.identity.ownerProcessIdentifier + 1,
                ownerProcessStartIdentity: requested.identity.ownerProcessStartIdentity + 1),
            bounds: requested.bounds,
            screenPoint: requested.screenPoint)
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in wrongOwner },
            routeIsCurrent: { _ in true },
            makeEvent: { specification, point in
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: specification.type,
                    mouseCursorPosition: point,
                    mouseButton: specification.button)
            },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in posted += 1; return true },
            postPublic: { _, _ in posted += 1 },
            resolveTransport: { _ in .publicCGEvent },
            sleep: { _ in })

        do {
            _ = try await driver.click(
                at: requested.screenPoint,
                button: .left,
                count: 2,
                targetProcessIdentifier: requested.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(requested.identity.windowID))
            Issue.record("Expected the mismatched receipt to be refused")
        } catch let PeekabooError.snapshotStale(message) {
            #expect(message.contains("does not match"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(posted == 0)
    }

    @Test
    @MainActor
    func `captured process generation cannot rebind at final pointer dispatch`() async {
        var postCount = 0
        let captured = Self.receipt()
        let replacement = WindowRoutedPointerDriver.RouteReceipt(
            identity: WindowMutationIdentity(
                windowID: captured.identity.windowID,
                ownerProcessIdentifier: captured.identity.ownerProcessIdentifier,
                ownerProcessStartIdentity: captured.identity.ownerProcessStartIdentity + 1),
            bounds: captured.bounds,
            screenPoint: captured.screenPoint)
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in replacement },
            routeIsCurrent: { _ in true },
            makeEvent: { specification, point in
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: specification.type,
                    mouseCursorPosition: point,
                    mouseButton: specification.button)
            },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in postCount += 1; return true },
            postPublic: { _, _ in postCount += 1 },
            sleep: { _ in })

        do {
            _ = try await driver.click(
                at: captured.screenPoint,
                button: .left,
                count: 1,
                targetProcessIdentifier: captured.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(captured.identity.windowID),
                expectedWindowIdentity: captured.identity,
                expectedWindowBounds: captured.bounds)
            Issue.record("Expected replacement process generation to be refused")
        } catch let PeekabooError.snapshotStale(message) {
            #expect(message.contains("does not match"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(postCount == 0)
    }

    @Test
    @MainActor
    func `same window ID and bounds owner swap is refused before posting`() async {
        var posted = 0
        let receipt = Self.receipt()
        let swappedOwnerWindow = SystemWindowIdentity(
            windowID: CGWindowID(receipt.identity.windowID),
            ownerProcessIdentifier: receipt.identity.ownerProcessIdentifier + 1,
            title: "Replacement",
            bounds: receipt.bounds,
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: .readOnly)
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { receipt in
                WindowRoutedPointerDriver.routeRemainsCurrent(
                    receipt,
                    identityIsCurrent: true,
                    finalWindow: swappedOwnerWindow,
                    finalProcessStartIdentity: receipt.identity.ownerProcessStartIdentity)
            },
            makeEvent: { specification, point in
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: specification.type,
                    mouseCursorPosition: point,
                    mouseButton: specification.button)
            },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in posted += 1; return true },
            postPublic: { _, _ in posted += 1 },
            resolveTransport: { _ in .publicCGEvent },
            sleep: { _ in })

        do {
            _ = try await driver.click(
                at: receipt.screenPoint,
                button: .left,
                count: 2,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID))
            Issue.record("Expected final owner swap refusal")
        } catch let PeekabooError.snapshotStale(message) {
            #expect(message.contains("changed owner"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(posted == 0)
    }

    @Test
    @MainActor
    func `route generation change between events stops partial delivery`() async {
        var specifications: [WindowRoutedPointerDriver.EventSpecification] = []
        var validationCount = 0
        let receipt = Self.receipt()
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { _ in
                validationCount += 1
                return validationCount == 1
            },
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
            postPublic: { _, _ in },
            resolveTransport: { _ in .publicCGEvent },
            sleep: { _ in })

        do {
            _ = try await driver.click(
                at: receipt.screenPoint,
                button: .left,
                count: 2,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID))
            Issue.record("Expected changed generation to stop delivery")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .click)
            #expect(error.emittedUnitCount == 1)
            #expect(!error.retrySafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(specifications.map(\.type) == [.mouseMoved])
    }

    @Test
    @MainActor
    func `route change after mouse down releases original process generation`() async {
        var specifications: [WindowRoutedPointerDriver.EventSpecification] = []
        var validationCount = 0
        var processGenerationChecks = 0
        let receipt = Self.receipt()
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { _ in
                validationCount += 1
                return validationCount <= 2
            },
            processGenerationIsCurrent: { _ in
                processGenerationChecks += 1
                return true
            },
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
            postPublic: { _, _ in },
            resolveTransport: { _ in .publicCGEvent },
            sleep: { _ in })

        do {
            _ = try await driver.click(
                at: receipt.screenPoint,
                button: .left,
                count: 1,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID))
            Issue.record("Expected indeterminate route-change result")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .click)
            #expect(error.emittedUnitCount == 3)
            #expect(error.causeDescription?.contains("paired mouse-up") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(specifications.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        #expect(processGenerationChecks == 2)
    }

    @Test
    @MainActor
    func `route change after mouse down never releases replacement process generation`() async {
        var specifications: [WindowRoutedPointerDriver.EventSpecification] = []
        var validationCount = 0
        let receipt = Self.receipt()
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, _ in receipt },
            routeIsCurrent: { _ in
                validationCount += 1
                return validationCount <= 2
            },
            processGenerationIsCurrent: { _ in false },
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
            postPublic: { _, _ in },
            resolveTransport: { _ in .publicCGEvent },
            sleep: { _ in })

        do {
            _ = try await driver.click(
                at: receipt.screenPoint,
                button: .right,
                count: 1,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID))
            Issue.record("Expected replacement generation refusal")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .click)
            #expect(error.emittedUnitCount == 2)
            #expect(error.causeDescription?.contains("replacement PID") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(specifications.map(\.type) == [.mouseMoved, .rightMouseDown])
    }

    @Test
    @MainActor
    func `cancellation during final pair cleanup is indeterminate after paired mouse up`() async {
        var specifications: [WindowRoutedPointerDriver.EventSpecification] = []
        var sleepCount = 0
        var downDelayContinuation: CheckedContinuation<Void, Never>?
        let receipt = Self.receipt()
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
            postPublic: { _, _ in },
            resolveTransport: { _ in .publicCGEvent },
            sleep: { _ in
                sleepCount += 1
                if sleepCount == 2 {
                    await withCheckedContinuation { continuation in
                        downDelayContinuation = continuation
                    }
                }
            })

        let task = Task { @MainActor in
            try await driver.click(
                at: receipt.screenPoint,
                button: .right,
                count: 1,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID))
        }
        while downDelayContinuation == nil {
            await Task.yield()
        }
        task.cancel()
        downDelayContinuation?.resume()

        do {
            _ = try await task.value
            Issue.record("Expected indeterminate cancellation after paired cleanup")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.causeDescription?.contains("cancel") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(specifications.map(\.type) == [.mouseMoved, .rightMouseDown, .rightMouseUp])
        #expect(specifications.map(\.clickState) == [0, 1, 1])
    }

    @Test
    @MainActor
    func `cancelling after first double click pair is indeterminate and stops second pair`() async {
        var specifications: [WindowRoutedPointerDriver.EventSpecification] = []
        var sleepCount = 0
        var interClickContinuation: CheckedContinuation<Void, Never>?
        let receipt = Self.receipt()
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
            postPublic: { _, _ in },
            resolveTransport: { _ in .publicCGEvent },
            sleep: { _ in
                sleepCount += 1
                if sleepCount == 3 {
                    await withCheckedContinuation { continuation in
                        interClickContinuation = continuation
                    }
                }
            })

        let task = Task { @MainActor in
            try await driver.click(
                at: receipt.screenPoint,
                button: .left,
                count: 2,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID))
        }
        while interClickContinuation == nil {
            await Task.yield()
        }
        task.cancel()
        interClickContinuation?.resume()

        do {
            _ = try await task.value
            Issue.record("Expected indeterminate cancellation before the second pair")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .click)
            #expect(error.emittedUnitCount == 3)
            #expect(!error.retrySafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(specifications.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        #expect(specifications.map(\.clickState) == [0, 1, 1])
    }

    @Test
    @MainActor
    func `cancelling after final emitted pair is retry unsafe`() async {
        var specifications: [WindowRoutedPointerDriver.EventSpecification] = []
        var publicPostCount = 0
        let receipt = Self.receipt()
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
            postPublic: { _, _ in
                publicPostCount += 1
                if publicPostCount == 3 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            },
            resolveTransport: { _ in .publicCGEvent },
            sleep: { _ in })

        let task = Task { @MainActor in
            try await driver.click(
                at: receipt.screenPoint,
                button: .left,
                count: 1,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID))
        }
        do {
            _ = try await task.value
            Issue.record("Expected final-pair cancellation to be indeterminate")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.causeDescription?.contains("cancel") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(specifications.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    @Test
    @MainActor
    func `pre-dispatch cancellation remains ordinary and emits nothing`() async {
        var specifications: [WindowRoutedPointerDriver.EventSpecification] = []
        let receipt = Self.receipt()
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
            postPublic: { _, _ in },
            resolveTransport: { _ in .publicCGEvent },
            sleep: { _ in })

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await driver.click(
                at: receipt.screenPoint,
                button: .left,
                count: 1,
                targetProcessIdentifier: receipt.identity.ownerProcessIdentifier,
                targetWindowID: CGWindowID(receipt.identity.windowID))
        }
        do {
            _ = try await task.value
            Issue.record("Expected ordinary pre-dispatch cancellation")
        } catch is CancellationError {
            // Expected before any event is created.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(specifications.isEmpty)
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
