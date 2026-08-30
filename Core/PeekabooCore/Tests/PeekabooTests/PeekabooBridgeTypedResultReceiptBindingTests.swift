import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeTypedResultReceiptBindingTests {
    @Test
    func `signed keyed read responses are bound live and offline`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let context = WindowContext(
            applicationName: "Fixture",
            applicationBundleId: "dev.peekaboo.fixture",
            applicationProcessId: 42,
            windowTitle: "Document",
            windowID: 71,
            windowBounds: fixture.windowIdentity.capturedBounds,
            windowMutationIdentity: fixture.windowIdentity)
        let detection = Self.detection(snapshotID: "snapshot", context: context)
        let app = Self.application(selector: "dev.peekaboo.fixture")
        let menu = MenuStructure(application: app, menus: [])
        let foundElement = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 10, y: 20, width: 80, height: 30))
        let valid: [(PeekabooBridgeRequest, PeekabooBridgeResponse)] = [
            (
                .detectElements(.init(imageData: Data([1]), snapshotId: "snapshot", windowContext: context)),
                .elementDetection(detection)),
            (.listMenus(.init(appIdentifier: "dev.peekaboo.fixture")), .menuStructure(menu)),
            (
                .waitForElement(.init(target: .elementId("B1"), timeout: 1, snapshotId: "snapshot")),
                .waitResult(.init(found: true, element: foundElement, waitTime: 0.1))),
            (.findDockItem(.init(name: "Safari")), .dockItem(.init(
                index: 0,
                title: "Safari",
                itemType: .application))),
            (.storeDetectionResult(.init(snapshotId: "snapshot", result: detection)), .ok),
            (.getDetectionResult(.init(snapshotId: "snapshot")), .detection(detection)),
            (
                .beginSnapshotMutation(.init(snapshotId: "snapshot")),
                .snapshotMutationLease(.init(snapshotId: "snapshot"))),
        ]
        for (offset, pair) in valid.enumerated() {
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(offset),
                request: pair.0,
                response: pair.1,
                target: .global)
            try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                bundle.receipt.payload,
                request: pair.0,
                response: pair.1)
            try bundle.validateIntegrity()
        }
    }

    @Test
    func `signed tree inspection binds selector constraints while allowing response enrichment`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolvedContext = Self.resolvedTreeContext(fixture: fixture)
        let response = PeekabooBridgeResponse.elementDetection(
            Self.detection(snapshotID: "resolved-tree", context: resolvedContext))
        let bundlePath = "/Applications/Fixture.app"
        let executablePath = bundlePath + "/Contents/MacOS/fixture"
        let validSelectors = [
            WindowContext(windowID: fixture.windowIdentity.windowID),
            WindowContext(
                applicationProcessId: fixture.windowIdentity.ownerProcessIdentifier,
                windowID: fixture.windowIdentity.windowID),
            WindowContext(
                applicationName: "Fixt",
                windowID: fixture.windowIdentity.windowID),
            WindowContext(applicationName: bundlePath, windowID: fixture.windowIdentity.windowID),
            WindowContext(applicationName: executablePath, windowID: fixture.windowIdentity.windowID),
            WindowContext(windowTitle: "dOcUmEnT", windowID: fixture.windowIdentity.windowID),
            WindowContext(windowTitle: "cume", windowID: fixture.windowIdentity.windowID),
            WindowContext(
                applicationBundleId: "dev.peekaboo.fixture",
                windowID: fixture.windowIdentity.windowID),
            WindowContext(
                applicationName: "Fixture",
                applicationBundleId: "dev.peekaboo.fixture",
                applicationProcessId: fixture.windowIdentity.ownerProcessIdentifier,
                windowTitle: "Document",
                windowID: fixture.windowIdentity.windowID,
                windowBounds: fixture.windowIdentity.capturedBounds,
                windowMutationIdentity: fixture.windowIdentity,
                shouldFocusWebContent: false,
                includeMenuBarElements: true,
                traversalBudget: AXTraversalBudget(),
                requiresFreshAccessibilityTree: false,
                accessibilityTimeoutSeconds: 20),
        ]
        for (offset, selector) in validSelectors.enumerated() {
            let request = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: selector))
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(offset),
                request: request,
                response: response,
                target: .window(fixture.windowIdentity))
            try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                bundle.receipt.payload,
                request: request,
                response: response)
            try bundle.validateIntegrity()
        }

        let wrongIdentity = WindowMutationIdentity(
            windowID: fixture.windowIdentity.windowID,
            ownerProcessIdentifier: fixture.windowIdentity.ownerProcessIdentifier,
            ownerProcessStartIdentity: fixture.windowIdentity.ownerProcessStartIdentity + 1,
            capturedBounds: fixture.windowIdentity.capturedBounds)
        let contradictorySelectors = [
            WindowContext(applicationName: "Other", windowID: fixture.windowIdentity.windowID),
            WindowContext(
                applicationName: "/Applications/Other.app",
                windowID: fixture.windowIdentity.windowID),
            WindowContext(
                applicationName: "/Applications/Fixture.app/Contents/MacOS/other",
                windowID: fixture.windowIdentity.windowID),
            WindowContext(applicationBundleId: "dev.peekaboo.other", windowID: fixture.windowIdentity.windowID),
            WindowContext(
                applicationProcessId: fixture.windowIdentity.ownerProcessIdentifier + 1,
                windowID: fixture.windowIdentity.windowID),
            WindowContext(windowTitle: "Other", windowID: fixture.windowIdentity.windowID),
            WindowContext(windowID: fixture.windowIdentity.windowID + 1),
            WindowContext(
                windowID: fixture.windowIdentity.windowID,
                windowBounds: CGRect(x: 1, y: 2, width: 3, height: 4)),
            WindowContext(
                windowID: fixture.windowIdentity.windowID,
                windowMutationIdentity: wrongIdentity),
            WindowContext(windowID: fixture.windowIdentity.windowID, includeMenuBarElements: false),
            WindowContext(
                windowID: fixture.windowIdentity.windowID,
                traversalBudget: AXTraversalBudget(maxDepth: 1)),
            WindowContext(
                windowID: fixture.windowIdentity.windowID,
                requiresFreshAccessibilityTree: true),
            WindowContext(
                windowID: fixture.windowIdentity.windowID,
                accessibilityTimeoutSeconds: 3),
        ]
        for (offset, selector) in contradictorySelectors.enumerated() {
            let request = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: selector))
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(validSelectors.count + offset),
                request: request,
                response: response,
                target: .window(fixture.windowIdentity))
            #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
                "element-detection response window context"))
            {
                try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                    bundle.receipt.payload,
                    request: request,
                    response: response)
            }
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try bundle.validateIntegrity()
            }
        }

        let unconstrainedRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(
            windowContext: WindowContext(windowID: fixture.windowIdentity.windowID)))
        let hostConfiguredResponse = PeekabooBridgeResponse.elementDetection(Self.detection(
            snapshotID: "host-configured-tree",
            context: Self.resolvedTreeContext(
                fixture: fixture,
                traversalBudget: AXTraversalBudget(
                    maxDepth: 7,
                    maxElementCount: 321,
                    maxChildrenPerNode: 45))))
        let hostConfiguredBundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: UInt64(validSelectors.count + contradictorySelectors.count),
            request: unconstrainedRequest,
            response: hostConfiguredResponse,
            target: .window(fixture.windowIdentity))
        try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
            hostConfiguredBundle.receipt.payload,
            request: unconstrainedRequest,
            response: hostConfiguredResponse)

        let hostileRefinements = [
            Self.resolvedTreeContext(fixture: fixture, shouldFocusWebContent: true),
            Self.resolvedTreeContext(fixture: fixture, includeMenuBarElements: false),
            Self.resolvedTreeContext(fixture: fixture, requiresFreshAccessibilityTree: true),
            Self.resolvedTreeContext(fixture: fixture, accessibilityTimeoutSeconds: 3),
        ]
        for (offset, context) in hostileRefinements.enumerated() {
            let forgedResponse = PeekabooBridgeResponse.elementDetection(
                Self.detection(snapshotID: "hostile-tree", context: context))
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(validSelectors.count + contradictorySelectors.count + 1 + offset),
                request: unconstrainedRequest,
                response: forgedResponse,
                target: .window(fixture.windowIdentity))
            #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
                "element-detection response window context"))
            {
                try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                    bundle.receipt.payload,
                    request: unconstrainedRequest,
                    response: forgedResponse)
            }
        }
    }

    @Test
    func `signed application partial tree drops exact window authority only with explicit opt in`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let processIdentity = fixture.windowIdentity.processIdentity
        let requestContext = WindowContext(
            windowID: fixture.windowIdentity.windowID,
            shouldFocusWebContent: false,
            includeMenuBarElements: true,
            traversalBudget: AXTraversalBudget(),
            requiresFreshAccessibilityTree: false,
            accessibilityTimeoutSeconds: 20,
            allowApplicationScopedAccessibilityFallback: true)
        let responseContext = WindowContext(
            applicationName: "Fixture",
            applicationBundleId: "dev.peekaboo.fixture",
            applicationBundlePath: "/Applications/Fixture.app",
            applicationExecutablePath: "/Applications/Fixture.app/Contents/MacOS/fixture",
            applicationProcessId: processIdentity.processIdentifier,
            applicationProcessStartIdentity: processIdentity.processStartIdentity,
            windowTitle: "Application-scoped partial semantics",
            shouldFocusWebContent: false,
            includeMenuBarElements: true,
            traversalBudget: AXTraversalBudget(),
            requiresFreshAccessibilityTree: false,
            accessibilityTimeoutSeconds: 20)
        let response = PeekabooBridgeResponse.elementDetection(Self.detection(
            snapshotID: "application-partial",
            context: responseContext,
            warnings: [DetectionMetadata.applicationScopedAccessibilityFallbackWarning],
            truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true),
            fallbackOrigin: ApplicationScopedAccessibilityFallbackOrigin(
                windowIdentity: fixture.windowIdentity)))
        let request = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: requestContext))
        let bundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 0,
            request: request,
            response: response,
            target: .process(processIdentity))

        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: request,
            response: response).target == .process(processIdentity))
        try bundle.validateIntegrity()

        let noOptInRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: WindowContext(
            applicationName: "Fixture",
            applicationProcessId: processIdentity.processIdentifier,
            windowID: fixture.windowIdentity.windowID)))
        let noOptInBundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 1,
            request: noOptInRequest,
            response: response,
            target: .process(processIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try noOptInBundle.validateIntegrity()
        }

        let wrongProcess = ApplicationProcessIdentity(
            processIdentifier: processIdentity.processIdentifier + 1,
            processStartIdentity: processIdentity.processStartIdentity + 1)
        let wrongProcessResponse = PeekabooBridgeResponse.elementDetection(Self.detection(
            snapshotID: "application-partial",
            context: WindowContext(
                applicationName: "Other",
                applicationProcessId: wrongProcess.processIdentifier,
                applicationProcessStartIdentity: wrongProcess.processStartIdentity),
            warnings: [DetectionMetadata.applicationScopedAccessibilityFallbackWarning],
            truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true),
            fallbackOrigin: ApplicationScopedAccessibilityFallbackOrigin(
                windowIdentity: fixture.windowIdentity)))
        let wrongProcessBundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 2,
            request: request,
            response: wrongProcessResponse,
            target: .process(wrongProcess))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try wrongProcessBundle.validateIntegrity()
        }

        let detectRequest = PeekabooBridgeRequest.detectElements(.init(
            imageData: Data([1]),
            snapshotId: "application-partial",
            windowContext: requestContext))
        let detectBundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 3,
            request: detectRequest,
            response: response,
            target: .global)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try detectBundle.validateIntegrity()
        }

        let missingIncompleteResponse = PeekabooBridgeResponse.elementDetection(Self.detection(
            snapshotID: "application-partial",
            context: responseContext,
            warnings: [DetectionMetadata.applicationScopedAccessibilityFallbackWarning],
            fallbackOrigin: ApplicationScopedAccessibilityFallbackOrigin(
                windowIdentity: fixture.windowIdentity)))
        let missingIncompleteBundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 4,
            request: request,
            response: missingIncompleteResponse,
            target: .process(processIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try missingIncompleteBundle.validateIntegrity()
        }
    }

    @Test
    func `signed detect projection binds only explicitly requested application paths`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let pathless = Self.exactDetectionContext(
            fixture: fixture,
            applicationBundlePath: nil,
            applicationExecutablePath: nil)
        let pathlessRequest = PeekabooBridgeRequest.detectElements(.init(
            imageData: Data([1]),
            snapshotId: "snapshot",
            windowContext: pathless))
        let pathlessResponse = PeekabooBridgeResponse.elementDetection(
            Self.detection(snapshotID: "snapshot", context: pathless))
        let pathlessBundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 0,
            request: pathlessRequest,
            response: pathlessResponse,
            target: .global)
        try pathlessBundle.validateIntegrity()

        let canonical = Self.exactDetectionContext(
            fixture: fixture,
            applicationBundlePath: "/Applications/Fixture.app",
            applicationExecutablePath: "/Applications/Fixture.app/Contents/MacOS/fixture")
        let canonicalRequest = PeekabooBridgeRequest.detectElements(.init(
            imageData: Data([1]),
            snapshotId: "snapshot",
            windowContext: canonical))
        let canonicalResponse = PeekabooBridgeResponse.elementDetection(
            Self.detection(snapshotID: "snapshot", context: canonical))
        let canonicalBundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 1,
            request: canonicalRequest,
            response: canonicalResponse,
            target: .global)
        try canonicalBundle.validateIntegrity()

        let contradictory = Self.exactDetectionContext(
            fixture: fixture,
            applicationBundlePath: "/Applications/Other.app",
            applicationExecutablePath: "/Applications/Other.app/Contents/MacOS/other")
        let contradictoryRequest = PeekabooBridgeRequest.detectElements(.init(
            imageData: Data([1]),
            snapshotId: "snapshot",
            windowContext: contradictory))
        let contradictoryBundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 2,
            request: contradictoryRequest,
            response: canonicalResponse,
            target: .global)
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "element-detection response window context"))
        {
            try contradictoryBundle.validateIntegrity()
        }
    }

    @Test
    func `forged keyed read responses fail live and offline`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let context = WindowContext(
            applicationName: "Fixture",
            applicationBundleId: "dev.peekaboo.fixture",
            applicationProcessId: 42,
            windowTitle: "Document",
            windowID: 71,
            windowBounds: fixture.windowIdentity.capturedBounds,
            windowMutationIdentity: fixture.windowIdentity)
        let wrongContext = WindowContext(
            applicationName: "Other",
            applicationBundleId: "dev.peekaboo.other",
            applicationProcessId: 43,
            windowTitle: "Other",
            windowID: 72,
            windowBounds: fixture.windowIdentity.capturedBounds)
        let detection = Self.detection(snapshotID: "snapshot", context: context)
        let forgeries: [(PeekabooBridgeRequest, PeekabooBridgeResponse)] = [
            (
                .detectElements(.init(imageData: Data([1]), snapshotId: "snapshot", windowContext: context)),
                .elementDetection(Self.detection(snapshotID: "other", context: context))),
            (
                .detectElements(.init(imageData: Data([1]), snapshotId: "snapshot", windowContext: context)),
                .elementDetection(Self.detection(snapshotID: "snapshot", context: wrongContext))),
            (
                .listMenus(.init(appIdentifier: "dev.peekaboo.fixture")),
                .menuStructure(.init(application: Self.application(selector: "dev.peekaboo.other"), menus: []))),
            (
                .waitForElement(.init(target: .elementId("B1"), timeout: 1, snapshotId: "snapshot")),
                .waitResult(.init(
                    found: true,
                    element: .init(
                        id: "B2",
                        type: .button,
                        label: "Save",
                        bounds: CGRect(x: 10, y: 20, width: 80, height: 30)),
                    waitTime: 0.1))),
            (
                .findDockItem(.init(name: "Safari")),
                .dockItem(.init(index: 0, title: "Calendar", itemType: .application))),
            (
                .storeDetectionResult(.init(snapshotId: "outer", result: detection)),
                .ok),
            (
                .getDetectionResult(.init(snapshotId: "snapshot")),
                .detection(Self.detection(snapshotID: "other", context: context))),
            (
                .beginSnapshotMutation(.init(snapshotId: "snapshot")),
                .snapshotMutationLease(.init(snapshotId: "other"))),
        ]
        for (offset, pair) in forgeries.enumerated() {
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(offset),
                request: pair.0,
                response: pair.1,
                target: .global)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                    bundle.receipt.payload,
                    request: pair.0,
                    response: pair.1)
            }
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try bundle.validateIntegrity()
            }
        }
    }

    @Test
    func `signed type result is bound to request counts and dispatch units`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let actions: [TypeAction] = [
            .text("A👨‍👩‍👧‍👦"),
            .key(.tab),
            .clear,
            .text(""),
        ]
        let rawRequest = PeekabooBridgeRequest.typeActions(.init(
            actions: actions,
            cadence: .fixed(milliseconds: 0),
            snapshotId: "snapshot"))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let expectedResult = BridgeTestFixtures.typeResult(for: actions)
        #expect(expectedResult.totalCharacters == 2)
        #expect(expectedResult.keyPresses == 5)

        let plan = PeekabooBridgeOperationResultSemantics.semanticPlan(for: request)
        #expect(plan.typedResponseRule == .typeActions(.init(actions: actions)))
        #expect(plan.typedResponseRule.typeActionDispatchUnits == .exact(5))
        #expect(plan.deliveryRules.allSatisfy { $0.units == .variable })

        let validResponse = Self.typeResponse(result: expectedResult, dispatchedUnits: 5)
        let validBundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 0,
            request: request,
            response: validResponse,
            target: .global)
        try validBundle.validate()

        let forgedResponses = [
            Self.typeResponse(
                result: .init(totalCharacters: 3, keyPresses: 5),
                dispatchedUnits: 5),
            Self.typeResponse(
                result: .init(totalCharacters: 2, keyPresses: 4),
                dispatchedUnits: 5),
            Self.typeResponse(result: expectedResult, dispatchedUnits: 4),
        ]
        for (offset, response) in forgedResponses.enumerated() {
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(offset + 1),
                request: request,
                response: response,
                target: .global)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try bundle.validate()
            }
        }
    }

    @Test
    func `signed type result rejects a dispatched zero-emission request`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rawRequest = PeekabooBridgeRequest.typeActions(.init(
            actions: [.text("")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: "snapshot"))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let response = Self.typeResponse(
            result: .init(totalCharacters: 0, keyPresses: 0),
            dispatchedUnits: 1)
        let bundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 0,
            request: request,
            response: response,
            target: .global)

        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "type response zero-emission success"))
        {
            try bundle.validate()
        }
    }
}

extension PeekabooBridgeTypedResultReceiptBindingTests {
    @Test
    func `signed exact type correlates multiple AX clears key counts units and delivery`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let actions: [TypeAction] = [.clear, .clear, .text("x")]
        let bounds = try #require(fixture.windowIdentity.capturedBounds)
        let rawRequest = PeekabooBridgeRequest.exactWindowTargetedTypeActions(.init(
            actions: actions,
            cadence: .fixed(milliseconds: 0),
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            expectedWindowIdentity: fixture.windowIdentity,
            expectedWindowBounds: bounds,
            expectedFocusedElement: nil))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let plan = PeekabooBridgeOperationResultSemantics.semanticPlan(for: request)
        #expect(plan.typedResponseRule.typeActionDispatchUnits == .oneOf([3, 4, 5]))

        let valid: [(TypeResult, Int, DesktopActionOutcome.Delivery.Mechanism)] = [
            (.init(totalCharacters: 1, keyPresses: 5, specialKeyPresses: 4), 5, .windowTargetedEvents),
            (.init(totalCharacters: 1, keyPresses: 4, specialKeyPresses: 4), 5, .composite),
            (.init(totalCharacters: 1, keyPresses: 3, specialKeyPresses: 2), 4, .composite),
            (.init(totalCharacters: 1, keyPresses: 2, specialKeyPresses: 2), 4, .composite),
            (.init(totalCharacters: 1, keyPresses: 1, specialKeyPresses: 0), 3, .composite),
            (.init(totalCharacters: 1, keyPresses: 0, specialKeyPresses: 0), 3, .accessibilityValue),
        ]
        for (offset, shape) in valid.enumerated() {
            let response = Self.typeResponse(
                result: shape.0,
                dispatchedUnits: shape.1,
                delivery: .init(mechanism: shape.2, mode: .background))
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(offset),
                request: request,
                response: response,
                target: .window(fixture.windowIdentity))
            try bundle.validate()
        }

        let forged: [(TypeResult, Int, DesktopActionOutcome.Delivery.Mechanism)] = [
            (.init(totalCharacters: 1, keyPresses: 1), 3, .accessibilityValue),
            (.init(totalCharacters: 1, keyPresses: 3), 3, .composite),
            (.init(totalCharacters: 1, keyPresses: 5), 5, .composite),
            (.init(totalCharacters: 1, keyPresses: 1), 4, .composite),
            (.init(totalCharacters: 1, keyPresses: 2, specialKeyPresses: 0), 4, .composite),
        ]
        for (offset, shape) in forged.enumerated() {
            let response = Self.typeResponse(
                result: shape.0,
                dispatchedUnits: shape.1,
                delivery: .init(mechanism: shape.2, mode: .background))
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(valid.count + offset),
                request: request,
                response: response,
                target: .window(fixture.windowIdentity))
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try bundle.validate()
            }
        }
    }

    @Test
    func `signed exact text and key routes preserve AX event and mixed delivery`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let actions: [TypeAction] = [.text("x"), .key(.space)]
        let bounds = try #require(fixture.windowIdentity.capturedBounds)
        let rawRequest = PeekabooBridgeRequest.exactWindowTargetedTypeActions(.init(
            actions: actions,
            cadence: .fixed(milliseconds: 0),
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            expectedWindowIdentity: fixture.windowIdentity,
            expectedWindowBounds: bounds,
            expectedFocusedElement: nil))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let plan = PeekabooBridgeOperationResultSemantics.semanticPlan(for: request)
        #expect(plan.typedResponseRule.typeActionDispatchUnits == .exact(2))

        typealias DeliveryShape = (
            keyPresses: Int,
            specialKeyPresses: Int,
            mechanism: DesktopActionOutcome.Delivery.Mechanism)
        let valid: [DeliveryShape] = [
            (0, 0, .accessibilityValue),
            (1, 0, .composite),
            (1, 1, .composite),
            (2, 1, .windowTargetedEvents),
        ]
        for (offset, shape) in valid.enumerated() {
            let response = Self.typeResponse(
                result: .init(
                    totalCharacters: 1,
                    keyPresses: shape.keyPresses,
                    specialKeyPresses: shape.specialKeyPresses),
                dispatchedUnits: 2,
                delivery: .init(mechanism: shape.mechanism, mode: .background))
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(offset),
                request: request,
                response: response,
                target: .window(fixture.windowIdentity))
            try bundle.validate()
        }

        let forged: [DeliveryShape] = [
            (0, 1, .accessibilityValue),
            (1, 2, .composite),
            (2, 0, .windowTargetedEvents),
        ]
        for (offset, shape) in forged.enumerated() {
            let response = Self.typeResponse(
                result: .init(
                    totalCharacters: 1,
                    keyPresses: shape.keyPresses,
                    specialKeyPresses: shape.specialKeyPresses),
                dispatchedUnits: 2,
                delivery: .init(mechanism: shape.mechanism, mode: .background))
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(valid.count + offset),
                request: request,
                response: response,
                target: .window(fixture.windowIdentity))
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try bundle.validate()
            }
        }
    }

    @Test
    func `signed exact deletion admits truthful zero dispatch`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let actions: [TypeAction] = [.key(.delete)]
        let bounds = try #require(fixture.windowIdentity.capturedBounds)
        let rawRequest = PeekabooBridgeRequest.exactWindowTargetedTypeActions(.init(
            actions: actions,
            cadence: .fixed(milliseconds: 0),
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            expectedWindowIdentity: fixture.windowIdentity,
            expectedWindowBounds: bounds,
            expectedFocusedElement: nil))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let plan = PeekabooBridgeOperationResultSemantics.semanticPlan(for: request)
        #expect(plan.typedResponseRule.typeActionDispatchUnits == .oneOf([0, 1]))

        let response = Self.typeResponse(
            result: .init(totalCharacters: 0, keyPresses: 0, specialKeyPresses: 0),
            outcome: .confirmedNoChange(route: .bridge))
        let bundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 0,
            request: request,
            response: response,
            target: .window(fixture.windowIdentity))
        try bundle.validate()

        let forged = Self.typeResponse(
            result: .init(totalCharacters: 0, keyPresses: 1, specialKeyPresses: 0),
            outcome: .confirmedNoChange(route: .bridge))
        let forgedBundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 1,
            request: request,
            response: forged,
            target: .window(fixture.windowIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forgedBundle.validate()
        }
    }

    @Test
    func `signed perform action failures preserve refusal and attributed dispatch outcomes`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = Self.performActionRequest
        let failures = [
            DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "Button unavailable before dispatch."),
            Self.performActionPartialFailure(fixture: fixture),
        ]
        for (sequence, failure) in failures.enumerated() {
            let response = Self.performActionFailureResponse(failure)
            let target: PeekabooBridgeOperationTargetReceipt? = failure.outcome.dispatchState.mutationDispatched
                ? .window(fixture.windowIdentity) : nil
            let bundle = try await fixture.session.signedBundle(
                authority: fixture.authority,
                sequence: UInt64(sequence),
                request: request,
                response: response,
                target: target,
                outcome: failure.outcome.projection)
            try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                bundle.receipt.payload,
                request: request,
                response: response)
            try bundle.validate(trustAnchor: .listenerAttestation(fixture.authority.attestation))
            #expect(bundle.receipt.payload.target == target)
            #expect(bundle.receipt.payload.outcome == failure.outcome.projection)
            #expect(bundle.receipt.payload.selectedLeafEvidence == nil)
            let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: bundle.canonicalResponse)
            guard case let .projectedAction(projected) = decoded,
                  case let .error(envelope) = projected.response
            else {
                Issue.record("Expected canonical perform-action failure bytes")
                continue
            }
            #expect(envelope.desktopActionFailure == failure)
        }
    }

    @Test
    func `signed perform action errors reject contradictory outcomes and invalid dispatch progress`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let validFailure = Self.performActionPartialFailure(fixture: fixture)
        let wrongCount = DesktopActionFailure.partial(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "A single AX action cannot dispatch two units.")
        let wrongDelivery = DesktopActionFailure.partial(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: .one,
            message: "AX actions cannot claim foreground global events.")
        let responses: [PeekabooBridgeResponse] = [
            .projectedAction(.init(
                response: .error(.init(code: .internalError, actionFailure: validFailure)),
                outcome: DesktopActionOutcome.refused(route: .bridge, reason: .targetUnavailable).projection)),
            .projectedAction(.init(
                response: .error(.init(code: .internalError, message: "Missing canonical failure outcome.")),
                outcome: validFailure.outcome.projection)),
            Self.performActionFailureResponse(wrongCount),
            Self.performActionFailureResponse(wrongDelivery),
        ]
        for (sequence, response) in responses.enumerated() {
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(sequence),
                request: Self.performActionRequest,
                response: response,
                target: .window(fixture.windowIdentity))
            #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch("projected error outcome")) {
                try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                    bundle.receipt.payload,
                    request: Self.performActionRequest,
                    response: response)
            }
            #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch("projected error outcome")) {
                try bundle.validate(trustAnchor: .listenerAttestation(fixture.authority.attestation))
            }
        }
    }

    @Test
    func `signed perform action failure rejects a mismatched attributed target`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let failure = Self.performActionPartialFailure(fixture: fixture).attributed(to: .init(
            processIdentifier: fixture.windowIdentity.ownerProcessIdentifier,
            processStartIdentity: fixture.windowIdentity.ownerProcessStartIdentity,
            windowID: fixture.windowIdentity.windowID + 1))
        let bundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 0,
            request: Self.performActionRequest,
            response: Self.performActionFailureResponse(failure),
            target: .window(fixture.windowIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch("canonical target attribution evidence")) {
            try bundle.validate(trustAnchor: .listenerAttestation(fixture.authority.attestation))
        }
    }

    @Test
    func `perform action failure rejects forged signatures and altered canonical response bytes`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let failure = Self.performActionPartialFailure(fixture: fixture)
        let response = Self.performActionFailureResponse(failure)
        let bundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 0,
            request: Self.performActionRequest,
            response: response,
            target: .window(fixture.windowIdentity))
        try bundle.validate(trustAnchor: .listenerAttestation(fixture.authority.attestation))
        var signature = bundle.receipt.signature
        signature[signature.startIndex] ^= 1
        let forgedBundle = try OperationReceiptSessionFixture.bundle(
            authority: fixture.authority,
            sessionAttestation: fixture.session.attestation,
            receipt: .init(payload: bundle.receipt.payload, signature: signature),
            request: Self.performActionRequest,
            response: response)
        #expect(throws: PeekabooBridgeOperationReceiptError.invalidOperationSignature) {
            try forgedBundle.validate(trustAnchor: .listenerAttestation(fixture.authority.attestation))
        }

        let alteredBundle = try OperationReceiptSessionFixture.bundle(
            authority: fixture.authority,
            sessionAttestation: fixture.session.attestation,
            receipt: bundle.receipt,
            request: Self.performActionRequest,
            response: Self.performActionFailureResponse(.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "Forged safe refusal replacing the signed partial failure.")))
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch("the exported verification bundle")) {
            try alteredBundle.validate(trustAnchor: .listenerAttestation(fixture.authority.attestation))
        }
    }

    @Test
    func `signed perform action result is bound to target action and value semantics`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rawRequest = PeekabooBridgeRequest.performAction(.init(
            target: "B1",
            actionName: "AXPress",
            snapshotId: "snapshot"))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let validResult = ElementActionResult(
            target: "B1",
            actionName: "AXPress",
            anchorPoint: CGPoint(x: 10, y: 20))
        let validResponse = Self.performActionResponse(validResult)
        let validBundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 0,
            request: request,
            response: validResponse,
            target: .window(fixture.windowIdentity))
        try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
            validBundle.receipt.payload,
            request: request,
            response: validResponse)
        try validBundle.validate()

        let forgedResults = [
            ElementActionResult(target: "B2", actionName: "AXPress", anchorPoint: nil),
            ElementActionResult(target: "B1", actionName: "AXShowMenu", anchorPoint: nil),
            ElementActionResult(
                target: "B1",
                actionName: "AXPress",
                anchorPoint: nil,
                oldValue: "before"),
            ElementActionResult(
                target: "B1",
                actionName: "AXPress",
                anchorPoint: nil,
                newValue: "after"),
        ]
        for (offset, result) in forgedResults.enumerated() {
            let response = Self.performActionResponse(result)
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(offset + 1),
                request: request,
                response: response,
                target: .window(fixture.windowIdentity))
            #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
                "perform-action response request semantics"))
            {
                try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                    bundle.receipt.payload,
                    request: request,
                    response: response)
            }
            #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
                "perform-action response request semantics"))
            {
                try bundle.validate()
            }
        }
    }

    @Test
    func `signed set value result is bound to target action and requested value`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rawRequest = PeekabooBridgeRequest.setValue(.init(
            target: "B1",
            value: .int(42),
            snapshotId: "snapshot"))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let validResult = ElementActionResult(
            target: "B1",
            actionName: "AXSetValue",
            anchorPoint: nil,
            oldValue: "41",
            newValue: "42")
        let validBundle = try await Self.signedBundle(
            fixture: fixture,
            sequence: 0,
            request: request,
            response: Self.setValueResponse(validResult),
            target: .window(fixture.windowIdentity))
        try validBundle.validate()

        let forgedResults = [
            ElementActionResult(target: "B2", actionName: "AXSetValue", anchorPoint: nil, newValue: "42"),
            ElementActionResult(target: "B1", actionName: "AXPress", anchorPoint: nil, newValue: "42"),
            ElementActionResult(
                target: "B1",
                actionName: "AXSetValue",
                anchorPoint: CGPoint(x: 1, y: 2),
                newValue: "42"),
            ElementActionResult(target: "B1", actionName: "AXSetValue", anchorPoint: nil, newValue: "41"),
        ]
        for (offset, result) in forgedResults.enumerated() {
            let bundle = try await Self.signedBundle(
                fixture: fixture,
                sequence: UInt64(offset + 1),
                request: request,
                response: Self.setValueResponse(result),
                target: .window(fixture.windowIdentity))
            #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
                "set-value response request semantics"))
            {
                try bundle.validate()
            }
        }
    }

    private struct Fixture {
        let root: URL
        let authority: PeekabooBridgeOperationReceiptAuthority
        let session: OperationReceiptSessionFixture
        let windowIdentity: WindowMutationIdentity
    }

    private static func makeFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp/pbor-typed-result-\(UUID().uuidString)", isDirectory: true)
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let bounds = CGRect(x: 20, y: 30, width: 640, height: 480)
        return Fixture(
            root: root,
            authority: authority,
            session: session,
            windowIdentity: .init(
                windowID: 71,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 1001,
                capturedBounds: bounds))
    }

    private static func detection(
        snapshotID: String,
        context: WindowContext?,
        warnings: [String] = [],
        truncationInfo: DetectionTruncationInfo? = nil,
        fallbackOrigin: ApplicationScopedAccessibilityFallbackOrigin? = nil) -> ElementDetectionResult
    {
        ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/\(snapshotID).png",
            elements: .init(),
            metadata: .init(
                detectionTime: 0,
                elementCount: 0,
                method: "fixture",
                warnings: warnings,
                windowContext: context,
                truncationInfo: truncationInfo,
                applicationScopedAccessibilityFallbackOrigin: fallbackOrigin))
    }

    private static func exactDetectionContext(
        fixture: Fixture,
        applicationBundlePath: String?,
        applicationExecutablePath: String?) -> WindowContext
    {
        WindowContext(
            applicationName: "Fixture",
            applicationBundleId: "dev.peekaboo.fixture",
            applicationBundlePath: applicationBundlePath,
            applicationExecutablePath: applicationExecutablePath,
            applicationProcessId: fixture.windowIdentity.ownerProcessIdentifier,
            windowTitle: "Document",
            windowID: fixture.windowIdentity.windowID,
            windowBounds: fixture.windowIdentity.capturedBounds,
            windowMutationIdentity: fixture.windowIdentity,
            shouldFocusWebContent: false,
            includeMenuBarElements: true,
            traversalBudget: AXTraversalBudget(),
            requiresFreshAccessibilityTree: false,
            accessibilityTimeoutSeconds: 20)
    }

    private static func resolvedTreeContext(
        fixture: Fixture,
        shouldFocusWebContent: Bool? = false,
        includeMenuBarElements: Bool? = true,
        traversalBudget: AXTraversalBudget? = AXTraversalBudget(),
        requiresFreshAccessibilityTree: Bool? = false,
        accessibilityTimeoutSeconds: TimeInterval? = 20) -> WindowContext
    {
        WindowContext(
            applicationName: "Fixture",
            applicationBundleId: "dev.peekaboo.fixture",
            applicationBundlePath: "/Applications/Fixture.app",
            applicationExecutablePath: "/Applications/Fixture.app/Contents/MacOS/fixture",
            applicationProcessId: fixture.windowIdentity.ownerProcessIdentifier,
            windowTitle: "Document",
            windowID: fixture.windowIdentity.windowID,
            windowBounds: fixture.windowIdentity.capturedBounds,
            windowMutationIdentity: fixture.windowIdentity,
            shouldFocusWebContent: shouldFocusWebContent,
            includeMenuBarElements: includeMenuBarElements,
            traversalBudget: traversalBudget,
            requiresFreshAccessibilityTree: requiresFreshAccessibilityTree ?? false,
            accessibilityTimeoutSeconds: accessibilityTimeoutSeconds)
    }

    private static func application(selector: String) -> ServiceApplicationInfo {
        let process = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        let proof = SelectorResolutionProof(
            scope: .application,
            normalizedSelector: selector,
            matchKind: .bundleIdentifier,
            matchPrecedence: SelectorResolutionProof.MatchKind.bundleIdentifier.precedence,
            selectedProcessIdentity: process,
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1,
            winningCandidateCount: 1,
            hasWinningTie: false)
        return ServiceApplicationInfo(
            processIdentifier: process.processIdentifier,
            processStartIdentity: process.processStartIdentity,
            bundleIdentifier: selector,
            name: selector == "dev.peekaboo.fixture" ? "Fixture" : "Other",
            selectorResolutionProofs: [proof])
    }

    private static func typeResponse(
        result: TypeResult,
        dispatchedUnits: Int,
        delivery: DesktopActionOutcome.Delivery = .init(
            mechanism: .globalEvents,
            mode: .foreground)) -> PeekabooBridgeResponse
    {
        .projectedAction(.init(
            response: .typeResult(result),
            outcome: DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(dispatchedUnits)).projection))
    }

    private static func typeResponse(
        result: TypeResult,
        outcome: DesktopActionOutcome) -> PeekabooBridgeResponse
    {
        .projectedAction(.init(
            response: .typeResult(result),
            outcome: outcome.projection))
    }

    private static var performActionRequest: PeekabooBridgeRequest {
        .projectedAction(.init(request: .performAction(.init(
            target: "B1",
            actionName: "AXPress",
            snapshotId: SnapshotReferenceFixtures.first.rawValue))))
    }

    private static func performActionPartialFailure(fixture: Fixture) -> DesktopActionFailure {
        .partial(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: .one,
            message: "The fixture AX action only partially completed.",
            hint: "Observe before retrying.",
            causeDescription: "fixture partial completion")
            .attributed(to: .init(
                processIdentifier: fixture.windowIdentity.ownerProcessIdentifier,
                processStartIdentity: fixture.windowIdentity.ownerProcessStartIdentity,
                windowID: fixture.windowIdentity.windowID))
    }

    private static func performActionFailureResponse(_ failure: DesktopActionFailure) -> PeekabooBridgeResponse {
        .projectedAction(.init(
            response: .error(.init(code: .internalError, actionFailure: failure)),
            outcome: failure.outcome.projection))
    }

    private static func performActionResponse(_ result: ElementActionResult) -> PeekabooBridgeResponse {
        .projectedAction(.init(
            response: .elementActionResult(result),
            outcome: DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one).projection))
    }

    private static func setValueResponse(_ result: ElementActionResult) -> PeekabooBridgeResponse {
        .projectedAction(.init(
            response: .elementActionResult(result),
            outcome: DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one).projection))
    }

    private static func signedBundle(
        fixture: Fixture,
        sequence: UInt64,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        target: PeekabooBridgeOperationTargetReceipt) async throws -> PeekabooBridgeOperationReceiptBundle
    {
        let claimed = try await fixture.session.acceptedClaim(
            authority: fixture.authority,
            sequence: sequence,
            request: request)
        defer { fixture.authority.complete(claimed.claim) }
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: fixture.authority,
            claim: claimed.claim,
            request: request,
            response: response,
            target: target,
            outcome: PeekabooBridgeOperationReceiptSemantics.outcome(in: response))
        let receipt = try await fixture.authority.signAndArchive(payload, claim: claimed.claim)
        return try OperationReceiptSessionFixture.bundle(
            authority: fixture.authority,
            sessionAttestation: fixture.session.attestation,
            receipt: receipt,
            request: request,
            response: response)
    }
}
