import ApplicationServices
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@_spi(Testing) @testable import PeekabooAutomationKit

struct DetachedAXObservationWorkerTests {
    @Test
    func `observation focus decoder accepts native and numeric booleans`() {
        #expect(DetachedAXObservationWorker.booleanAttributeValue(true) == true)
        #expect(DetachedAXObservationWorker.booleanAttributeValue(false) == false)
        #expect(DetachedAXObservationWorker.booleanAttributeValue(NSNumber(value: 1)) == true)
        #expect(DetachedAXObservationWorker.booleanAttributeValue(NSNumber(value: 0)) == false)
    }

    @Test
    func `observation focus decoder rejects unreadable values`() {
        #expect(DetachedAXObservationWorker.booleanAttributeValue(nil) == nil)
        #expect(DetachedAXObservationWorker.booleanAttributeValue("true") == nil)
        #expect(DetachedAXObservationWorker.booleanAttributeValue(NSNull()) == nil)
        #expect(DetachedAXObservationWorker.booleanAttributeValue([1]) == nil)
    }

    @Test
    func `identical bounds never substitute for an unproven exact window id`() {
        let sharedBounds = CGRect(x: 10, y: 20, width: 800, height: 600)
        let candidates = [
            DetachedAXWindowIdentityCandidate(windowID: nil, bounds: sharedBounds),
            DetachedAXWindowIdentityCandidate(windowID: nil, bounds: sharedBounds),
        ]

        #expect(DetachedAXExactWindowSelectionPolicy.uniqueExactIndex(
            windowID: 42,
            candidates: candidates) == nil)
    }

    @Test
    func `only a unique proven exact id is selected`() {
        let candidates = [
            DetachedAXWindowIdentityCandidate(windowID: 42, bounds: .zero),
            DetachedAXWindowIdentityCandidate(windowID: nil, bounds: .zero),
        ]

        #expect(DetachedAXExactWindowSelectionPolicy.uniqueExactIndex(
            windowID: 42,
            candidates: candidates) == 0)
    }

    @Test
    func `nonresponsive exact-window child resets timeout before probing next child`() {
        var events: [ExactWindowProbeEvent] = []
        var timeouts: [Float] = [0.2, 0.1]

        let candidates = DetachedAXObservationWorker.exactWindowCandidates(
            windows: [1, 2],
            remainingTimeout: { timeouts.removeFirst() },
            applyTimeout: { window, timeout in events.append(.timeout(window, timeout)) },
            windowID: { window in
                events.append(.probe(window))
                return window == 2 ? 42 : nil
            })

        #expect(candidates.map(\.windowID) == [nil, 42])
        #expect(DetachedAXExactWindowSelectionPolicy.uniqueExactIndex(
            windowID: 42,
            candidates: candidates) == 1)
        #expect(events == [
            .timeout(1, 0.2),
            .probe(1),
            .timeout(1, 0),
            .timeout(2, 0.1),
            .probe(2),
            .timeout(2, 0),
        ])
    }

    @Test
    func `failed descriptor read is incomplete rather than an absent element`() {
        #expect(DetachedAXObservationWorker.descriptorReadDisposition(
            error: .cannotComplete,
            values: nil) == .incomplete)
        #expect(DetachedAXObservationWorker.descriptorReadDisposition(
            error: .success,
            values: []) == .incomplete)
    }

    @Test
    func `unsupported descriptor batch uses safe single attribute fallback`() {
        #expect(DetachedAXObservationWorker.descriptorReadDisposition(
            error: .attributeUnsupported,
            values: nil) == .fallback)
    }

    @Test
    func `failed children read is incomplete rather than an empty child list`() {
        #expect(DetachedAXObservationWorker.childrenReadDisposition(
            error: .cannotComplete,
            values: nil) == .incomplete)
        #expect(DetachedAXObservationWorker.childrenReadDisposition(
            error: .success,
            values: []) == .incomplete)
    }

    @Test
    func `unsupported children batch uses canonical children fallback`() {
        #expect(DetachedAXObservationWorker.childrenReadDisposition(
            error: .attributeUnsupported,
            values: nil) == .fallback)
    }

    @Test
    func `embedded descriptor read failure makes an otherwise shaped batch incomplete`() throws {
        var values = [Any](
            repeating: NSNull(),
            count: DetachedAXObservationWorker.descriptorAttributeCount)
        values[0] = try Self.errorValue(.cannotComplete)

        #expect(DetachedAXObservationWorker.descriptorReadDisposition(
            error: .success,
            values: values) == .incomplete)
    }

    /// TextEdit's `AXTextArea` answers `AXDescription` with a generic `.failure`, and Finder's
    /// `AXWindow` root answers `AXValue` the same way. Treating that as an unreadable node dropped
    /// the element and abandoned its subtree, which is how a document's editable text area vanished
    /// from an otherwise healthy observation.
    @Test
    func `a declined descriptive attribute stays sparse for every role`() throws {
        for attribute in DetachedAXObservationWorker.descriptorAttributes
            where !AXAttributeReadCompletenessPolicy.nodeIdentityAttributeNames.contains(attribute)
        {
            let index = try #require(DetachedAXObservationWorker.descriptorAttributeIndex(attribute))
            for role in [kAXTextAreaRole, kAXWindowRole, kAXButtonRole, kAXGroupRole] {
                var values = try Self.usableDescriptorValues(role: role)
                values[index] = try Self.errorValue(.failure)
                #expect(DetachedAXObservationWorker.descriptorReadDisposition(
                    error: .success,
                    values: values) == .values)
            }
        }
    }

    @Test
    func `a declined node identity attribute still invalidates the node`() throws {
        for attribute in AXAttributeReadCompletenessPolicy.nodeIdentityAttributeNames {
            let index = try #require(DetachedAXObservationWorker.descriptorAttributeIndex(attribute))
            var values = try Self.usableDescriptorValues(role: kAXTextAreaRole)
            values[index] = try Self.errorValue(.failure)
            #expect(DetachedAXObservationWorker.descriptorReadDisposition(
                error: .success,
                values: values) == .incomplete)
        }
    }

    @Test
    func `an unanswered attribute read invalidates the node whatever it describes`() throws {
        let descriptionIndex = try #require(
            DetachedAXObservationWorker.descriptorAttributeIndex(kAXDescriptionAttribute))
        for error in [AXError.cannotComplete, .invalidUIElement, .apiDisabled] {
            var values = try Self.usableDescriptorValues(role: kAXTextAreaRole)
            values[descriptionIndex] = try Self.errorValue(error)
            #expect(DetachedAXObservationWorker.descriptorReadDisposition(
                error: .success,
                values: values) == .incomplete)
        }

        #expect(try DetachedAXObservationWorker.descriptorReadDisposition(
            error: .failure,
            values: Self.usableDescriptorValues(role: kAXTextAreaRole)) == .incomplete)
    }

    @Test
    func `embedded children read failure is not mistaken for an absent child list`() throws {
        var values = [Any](
            repeating: NSNull(),
            count: DetachedAXObservationWorker.childAttributeCount)
        values[0] = try Self.errorValue(.cannotComplete)

        #expect(DetachedAXObservationWorker.childrenReadDisposition(
            error: .success,
            values: values) == .incomplete)
    }

    @Test
    func `embedded unsupported attribute remains a complete sparse batch`() throws {
        var descriptorValues = [Any](
            repeating: NSNull(),
            count: DetachedAXObservationWorker.descriptorAttributeCount)
        descriptorValues[0] = try Self.errorValue(.attributeUnsupported)
        var childValues = [Any](
            repeating: NSNull(),
            count: DetachedAXObservationWorker.childAttributeCount)
        childValues[0] = try Self.errorValue(.attributeUnsupported)

        #expect(DetachedAXObservationWorker.descriptorReadDisposition(
            error: .success,
            values: descriptorValues) == .values)
        #expect(DetachedAXObservationWorker.childrenReadDisposition(
            error: .success,
            values: childValues) == .values)
    }

    @Test
    func `non-renderable structural node traverses descendants without being emitted`() {
        #expect(DetachedAXObservationWorker.nodeTraversalDisposition(
            descriptorAvailable: false,
            readIncomplete: false) == .traverseOnly)
        #expect(DetachedAXObservationWorker.nodeTraversalDisposition(
            descriptorAvailable: false,
            readIncomplete: true) == .stopIncomplete)
    }

    @Test
    func `exact element limit marks truncation only when sibling work remains`() {
        #expect(DetachedAXObservationWorker.postChildStopReason(
            elementCount: 10,
            maxElementCount: 10,
            deadlineExpired: false,
            hasRemainingWork: true) == .maxElementCount)
        #expect(DetachedAXObservationWorker.postChildStopReason(
            elementCount: 10,
            maxElementCount: 10,
            deadlineExpired: false,
            hasRemainingWork: false) == nil)
    }

    @Test
    func `expired deadline marks truncation when sibling work remains`() {
        #expect(DetachedAXObservationWorker.postChildStopReason(
            elementCount: 1,
            maxElementCount: 10,
            deadlineExpired: true,
            hasRemainingWork: true) == .deadline)
        #expect(DetachedAXObservationWorker.postChildStopReason(
            elementCount: 1,
            maxElementCount: 10,
            deadlineExpired: true,
            hasRemainingWork: false) == nil)
    }

    @Test
    func `exact window AX refusal is incomplete rather than a fake deadline`() {
        let immediate = DetachedAXObservationWorker.exactWindowResolutionFailureTruncation(
            deadlineReached: false)
        let expired = DetachedAXObservationWorker.exactWindowResolutionFailureTruncation(
            deadlineReached: true)

        #expect(immediate.incompleteAccessibilityRead)
        #expect(!immediate.deadlineReached)
        #expect(expired.deadlineReached)
        #expect(!expired.incompleteAccessibilityRead)
    }

    @Test
    @MainActor
    func `explicit accessibility timeout is not silently capped`() {
        #expect(ElementDetectionService.normalizedAccessibilityTimeout(nil) == 20)
        #expect(ElementDetectionService.normalizedAccessibilityTimeout(60) == 60)
        #expect(ElementDetectionService.normalizedAccessibilityTimeout(0.01) == 0.05)
    }

    @Test
    func `AX worker reserves bounded completion grace before the hard timeout`() {
        let long = DetachedAXObservationTiming(hardTimeoutSeconds: 60)
        #expect(long.cooperativeDeadlineSeconds == 59.75)
        #expect(long.hardTimeoutSeconds == 60)

        let short = DetachedAXObservationTiming(hardTimeoutSeconds: 0.05)
        #expect(abs(short.cooperativeDeadlineSeconds - 0.04) < 0.000_001)
        #expect(short.hardTimeoutSeconds == 0.05)
    }

    @Test
    @MainActor
    func `materially different traversal budgets bypass AX cache`() {
        #expect(ElementDetectionService.shouldUseAXTreeCache(
            budget: AXTraversalBudget(),
            requiresFreshAccessibilityTree: false))
        #expect(!ElementDetectionService.shouldUseAXTreeCache(
            budget: AXTraversalBudget(maxDepth: 4),
            requiresFreshAccessibilityTree: false))
        #expect(!ElementDetectionService.shouldUseAXTreeCache(
            budget: AXTraversalBudget(maxElementCount: 120),
            requiresFreshAccessibilityTree: false))
        #expect(!ElementDetectionService.shouldUseAXTreeCache(
            budget: AXTraversalBudget(maxChildrenPerNode: 40),
            requiresFreshAccessibilityTree: false))
        #expect(!ElementDetectionService.shouldUseAXTreeCache(
            budget: AXTraversalBudget(),
            requiresFreshAccessibilityTree: true))
    }

    @Test
    func `settable metadata is omitted when the bounded AX query is inconclusive`() {
        #expect(DetachedAXObservationWorker.valueSettableMetadata(
            error: .success,
            isSettable: true) == true)
        #expect(DetachedAXObservationWorker.valueSettableMetadata(
            error: .success,
            isSettable: false) == false)
        #expect(DetachedAXObservationWorker.valueSettableMetadata(
            error: .cannotComplete,
            isSettable: true) == nil)
    }

    @Test
    func `process reuse before detached worker fails closed`() {
        let request = Self.identityRequest()

        #expect(throws: PeekabooError.self) {
            try DetachedAXObservationWorker.validateIdentity(
                request,
                processStartIdentityProvider: { _ in 8 },
                windowIdentityProvider: { _ in nil },
                receiptValidator: { _, _ in true })
        }
    }

    @Test
    func `process reuse during detached worker fails post-traversal validation`() throws {
        let request = Self.identityRequest()
        var generations: [UInt64] = [7, 8]
        let generation: (pid_t) -> UInt64? = { _ in generations.removeFirst() }

        try DetachedAXObservationWorker.validateIdentity(
            request,
            processStartIdentityProvider: generation,
            windowIdentityProvider: { _ in nil },
            receiptValidator: { _, _ in true })
        #expect(throws: PeekabooError.self) {
            try DetachedAXObservationWorker.validateIdentity(
                request,
                processStartIdentityProvider: generation,
                windowIdentityProvider: { _ in nil },
                receiptValidator: { _, _ in true })
        }
    }

    @Test
    func `window receipt reuse during detached worker fails post-traversal validation`() throws {
        let request = Self.identityRequest()
        var receiptChecks = [true, false]
        let validateReceipt: (WindowMutationIdentity, CGRect) -> Bool = { _, _ in receiptChecks.removeFirst() }

        try DetachedAXObservationWorker.validateIdentity(
            request,
            processStartIdentityProvider: { _ in 7 },
            windowIdentityProvider: { _ in nil },
            receiptValidator: validateReceipt)
        #expect(throws: PeekabooError.self) {
            try DetachedAXObservationWorker.validateIdentity(
                request,
                processStartIdentityProvider: { _ in 7 },
                windowIdentityProvider: { _ in nil },
                receiptValidator: validateReceipt)
        }
    }

    private static func identityRequest() -> DetachedAXObservationRequest {
        DetachedAXObservationRequest(
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
            timing: DetachedAXObservationTiming(hardTimeoutSeconds: 1))
    }

    private static func usableDescriptorValues(role: String) throws -> [Any] {
        var position = CGPoint(x: 10, y: 20)
        var size = CGSize(width: 800, height: 600)
        var values = [Any](
            repeating: NSNull(),
            count: DetachedAXObservationWorker.descriptorAttributeCount)
        let positionIndex = try #require(
            DetachedAXObservationWorker.descriptorAttributeIndex(kAXPositionAttribute))
        let sizeIndex = try #require(DetachedAXObservationWorker.descriptorAttributeIndex(kAXSizeAttribute))
        let roleIndex = try #require(DetachedAXObservationWorker.descriptorAttributeIndex(kAXRoleAttribute))
        values[positionIndex] = try #require(AXValueCreate(.cgPoint, &position))
        values[sizeIndex] = try #require(AXValueCreate(.cgSize, &size))
        values[roleIndex] = role
        return values
    }

    private static func errorValue(_ error: AXError) throws -> AXValue {
        var error = error
        return try #require(AXValueCreate(.axError, &error))
    }
}

private enum ExactWindowProbeEvent: Equatable {
    case timeout(Int, Float)
    case probe(Int)
}
