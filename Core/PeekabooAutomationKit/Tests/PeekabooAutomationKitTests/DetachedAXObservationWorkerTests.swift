import ApplicationServices
import CoreGraphics
import PeekabooFoundation
import Testing
@_spi(Testing) @testable import PeekabooAutomationKit

struct DetachedAXObservationWorkerTests {
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
            timeoutSeconds: 1)
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
