import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

struct ObservedFocusCorroborationTests {
    private static let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
    private static let fieldFrame = CGRect(x: 150, y: 180, width: 250, height: 30)
    private static let orders = [
        [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
    ]
    private static let truncations = [
        DetectionTruncationInfo(maxDepthReached: true),
        DetectionTruncationInfo(maxElementCountReached: true),
        DetectionTruncationInfo(maxChildrenPerNodeReached: true),
        DetectionTruncationInfo(deadlineReached: true),
        DetectionTruncationInfo(incompleteAccessibilityRead: true),
    ]

    @Test(arguments: [true, nil] as [Bool?])
    func `stalled optional focus read leaves short deadline available for ordinary traversal`(focused: Bool?) throws {
        let timing = DetachedAXObservationTiming(hardTimeoutSeconds: 0.05)
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(timing.cooperativeDeadlineSeconds))
        var now = started.advanced(by: .milliseconds(4))
        var readTimeouts: [Float] = []
        let initial: Int? = DetachedAXObservationWorker.initialFocusedReference(deadline: deadline, now: now) {
            readTimeouts.append($0)
            now = now.advanced(by: .seconds(Double($0)))
            return nil
        }

        #expect(initial == nil)
        #expect(readTimeouts.count == 1)
        let readTimeout = try #require(readTimeouts.first)
        #expect(abs(readTimeout - 0.009) < 0.000_001)

        let traverse = { () -> [DetectedElement] in
            let completed = now.advanced(by: .milliseconds(20))
            guard completed < deadline else { return [] }
            now = completed
            return [self.element(id: "field", focused: focused)]
        }
        let elements = traverse()
        let result = self.result(elements: elements, corroboratedElementID: nil)

        #expect(elements.count == 1)
        #expect(now < deadline)
        #expect(now.duration(to: deadline) < .milliseconds(12))
        #expect(readTimeouts.count == 1)
        if focused == true {
            #expect(result.metadata.windowContext?.focusedElement?.identifier == "native-field")
        } else {
            #expect(result.metadata.windowContext?.focusedElement == nil)
            #expect(result.elements.textFields.first?.isFocused == nil)
        }
    }

    @Test(arguments: [0.037, 0.039, 0.04, 0.05])
    func `initial focus read skips insufficient or expired deadline without restarting`(elapsed: TimeInterval) {
        let started = ContinuousClock.now
        let timing = DetachedAXObservationTiming(hardTimeoutSeconds: 0.05)
        let deadline = started.advanced(by: .seconds(timing.cooperativeDeadlineSeconds))
        var reads = 0

        let initial: Int? = DetachedAXObservationWorker.initialFocusedReference(
            deadline: deadline,
            now: started.advanced(by: .seconds(elapsed)))
        { _ in
            reads += 1
            return 3
        }

        #expect(initial == nil)
        #expect(reads == 0)
    }

    @Test
    func `initial focus read stays capped when ordinary traversal has a long deadline`() {
        let now = ContinuousClock.now
        var readTimeouts: [Float] = []
        let initial = DetachedAXObservationWorker.initialFocusedReference(
            deadline: now.advanced(by: .seconds(20)),
            now: now)
        {
            readTimeouts.append($0)
            return 3
        }

        #expect(initial == 3)
        #expect(readTimeouts == [0.05])
    }

    @Test(arguments: [0.1, 0.5])
    func `menu read replaces initial focus timeout with current remaining budget`(remaining: TimeInterval) {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(1))
        var applicationTimeout: Float = 0.2
        var now = started
        let initial = DetachedAXObservationWorker.initialFocusedReference(deadline: deadline, now: now) {
            applicationTimeout = $0
            now = now.advanced(by: .seconds(Double($0)))
            return 3
        }
        #expect(initial == 3)
        #expect(applicationTimeout == 0.05)

        now = deadline.advanced(by: .seconds(-remaining))
        var appliedTimeouts: [Float] = []
        var menuReads = 0
        let menu: String? = DetachedAXObservationWorker.readApplicationReference(
            deadline: deadline,
            now: now,
            applyTimeout: {
                applicationTimeout = $0
                appliedTimeouts.append($0)
                return true
            },
            read: {
                menuReads += 1
                guard applicationTimeout >= 0.075 else { return nil }
                now = now.advanced(by: .milliseconds(75))
                return "menu"
            })

        #expect(menu == "menu")
        #expect(menuReads == 1)
        #expect(appliedTimeouts == [Float(min(0.2, remaining))])
        #expect(now < deadline)
    }

    @Test(arguments: [0.0, -0.01])
    func `menu read skips expired deadline without reusing initial focus timeout`(remaining: TimeInterval) {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(1))
        var applicationTimeout: Float = 0.2
        let initial = DetachedAXObservationWorker.initialFocusedReference(deadline: deadline, now: started) {
            applicationTimeout = $0
            return 3
        }
        var timeoutApplications = 0
        var menuReads = 0

        let menu: String? = DetachedAXObservationWorker.readApplicationReference(
            deadline: deadline,
            now: deadline.advanced(by: .seconds(-remaining)),
            applyTimeout: {
                applicationTimeout = $0
                timeoutApplications += 1
                return true
            },
            read: {
                menuReads += 1
                return "menu"
            })

        #expect(initial == 3)
        #expect(applicationTimeout == 0.05)
        #expect(menu == nil)
        #expect(timeoutApplications == 0)
        #expect(menuReads == 0)
    }

    @Test
    func `application reference read requires successful timeout installation`() {
        let now = ContinuousClock.now
        var reads = 0
        let reference: Int? = DetachedAXObservationWorker.readApplicationReference(
            deadline: now.advanced(by: .seconds(1)),
            now: now,
            applyTimeout: { _ in false },
            read: {
                reads += 1
                return 3
            })

        #expect(reference == nil)
        #expect(reads == 0)
    }

    @Test(arguments: Self.orders)
    func `stable authority selects the emitted reference independent of insertion order`(order: [Int]) {
        let entries = [("outer", 1), ("inner", 2), ("field", 3)]
        var candidates: [String: Int] = [:]
        for index in order {
            candidates[entries[index].0] = entries[index].1
        }
        var currentReads = 0
        var ownerReferences: [Int] = []

        let result = DetachedAXObservationWorker.corroboratedFocusElementID(
            observation: (initialReference: 3, candidates: candidates, isComplete: true),
            canRead: { true },
            readCurrentReference: {
                currentReads += 1
                return 3
            },
            referencesEqual: ==,
            belongsToWindow: {
                ownerReferences.append($0)
                return true
            })

        #expect(result == "field")
        #expect(currentReads == 1)
        #expect(ownerReferences == [3])
    }

    @Test(arguments: EligibilityFailure.allCases)
    func `ineligible observation performs no current or owner read`(failure: EligibilityFailure) {
        let candidates = switch failure {
        case .noCandidates: [String: Int]()
        case .oneCandidate: ["field": 3]
        default: ["outer": 1, "field": 3]
        }
        var currentReads = 0
        var ownerReads = 0

        let result = DetachedAXObservationWorker.corroboratedFocusElementID(
            observation: (
                initialReference: failure == .missingInitial ? nil : 3,
                candidates: candidates,
                isComplete: failure != .incomplete),
            canRead: { failure != .expiredDeadline },
            readCurrentReference: {
                currentReads += 1
                return 3
            },
            referencesEqual: ==,
            belongsToWindow: { _ in
                ownerReads += 1
                return true
            })

        #expect(result == nil)
        #expect(currentReads == 0)
        #expect(ownerReads == 0)
    }

    @Test(arguments: [nil, 2] as [Int?])
    func `missing or changed current authority refuses before owner validation`(current: Int?) {
        var currentReads = 0
        var ownerReads = 0

        let result = DetachedAXObservationWorker.corroboratedFocusElementID(
            observation: (
                initialReference: 3,
                candidates: ["outer": 1, "inner": 2, "field": 3],
                isComplete: true),
            canRead: { true },
            readCurrentReference: {
                currentReads += 1
                return current
            },
            referencesEqual: ==,
            belongsToWindow: { _ in
                ownerReads += 1
                return true
            })

        #expect(result == nil)
        #expect(currentReads == 1)
        #expect(ownerReads == 0)
    }

    @Test(arguments: [false, true])
    func `absent or duplicate native correspondence cannot choose an emitted id`(duplicate: Bool) {
        var ownerReads = 0
        let candidates = duplicate
            ? ["outer": 1, "field": 3, "alias": 3]
            : ["outer": 1, "inner": 2]

        let result = DetachedAXObservationWorker.corroboratedFocusElementID(
            observation: (initialReference: 3, candidates: candidates, isComplete: true),
            canRead: { true },
            readCurrentReference: { 3 },
            referencesEqual: ==,
            belongsToWindow: { _ in
                ownerReads += 1
                return true
            })

        #expect(result == nil)
        #expect(ownerReads == 0)
    }

    @Test(arguments: [false, true])
    func `matching reference still requires both process and exact window ownership`(wrongProcess: Bool) {
        let authority = Reference(
            identity: 3,
            processIdentifier: wrongProcess ? 701 : 700,
            windowID: wrongProcess ? 42 : 43)
        let group = Reference(identity: 1, processIdentifier: 700, windowID: 42)
        var ownerReads = 0

        let result = DetachedAXObservationWorker.corroboratedFocusElementID(
            observation: (
                initialReference: authority,
                candidates: ["outer": group, "field": authority],
                isComplete: true),
            canRead: { true },
            readCurrentReference: { authority },
            referencesEqual: { $0.identity == $1.identity },
            belongsToWindow: {
                ownerReads += 1
                return $0.processIdentifier == 700 && $0.windowID == 42
            })

        #expect(result == nil)
        #expect(ownerReads == 1)
    }

    @Test(arguments: DeadlineStage.allCases)
    func `deadline expiry during corroboration never publishes late evidence`(stage: DeadlineStage) {
        var readable = true
        var currentReads = 0
        var comparisons = 0
        var ownerReads = 0

        let result = DetachedAXObservationWorker.corroboratedFocusElementID(
            observation: (initialReference: 3, candidates: ["outer": 1, "field": 3], isComplete: true),
            canRead: { readable },
            readCurrentReference: {
                currentReads += 1
                if stage == .currentRead {
                    readable = false
                }
                return 3
            },
            referencesEqual: {
                comparisons += 1
                if stage == .correspondence, comparisons > 1 {
                    readable = false
                }
                return $0 == $1
            },
            belongsToWindow: { _ in
                ownerReads += 1
                if stage == .ownership {
                    readable = false
                }
                return true
            })

        #expect(result == nil)
        #expect(currentReads == 1)
        #expect(ownerReads == (stage == .ownership ? 1 : 0))
    }

    @Test(arguments: Self.orders)
    func `group group field ambiguity is corroborated without rewriting raw focus flags`(order: [Int]) throws {
        let original = self.ambiguousElements()
        let elements = order.map { original[$0] }

        #expect(throws: FocusedElementReceiptError.multipleFocusedElements) {
            _ = try FocusedElementReceiptResolver.uniqueReceipt(elements: elements, context: self.context())
        }
        #expect(FocusedElementReceiptResolver.attachingObservedFocus(
            to: self.context(),
            elements: elements)?.focusedElement == nil)
        let attached = FocusedElementReceiptResolver.attachingObservedFocus(
            to: self.context(),
            elements: elements,
            corroboratedElementID: "field")
        let receipt = try #require(attached?.focusedElement)

        #expect(receipt.processIdentifier == 700)
        #expect(receipt.windowID == 42)
        #expect(receipt.role == "AXTextField")
        #expect(receipt.identifier == "native-field")
        #expect(receipt.frame == Self.fieldFrame)
        #expect(elements.map(\.isFocused) == [true, true, true])
    }

    @Test(arguments: [nil, "absent", "native-field"] as [String?])
    func `missing unmatched or AX identifier hints cannot resolve ambiguity`(hint: String?) {
        let attached = FocusedElementReceiptResolver.attachingObservedFocus(
            to: self.context(),
            elements: self.ambiguousElements(),
            corroboratedElementID: hint)

        #expect(attached?.focusedElement == nil)
    }

    @Test(arguments: [false, true])
    func `duplicate emitted id refuses even when only one duplicate reports focus`(duplicateFocused: Bool) {
        let elements = self.ambiguousElements() + [self.element(id: "field", focused: duplicateFocused)]
        let attached = FocusedElementReceiptResolver.attachingObservedFocus(
            to: self.context(),
            elements: elements,
            corroboratedElementID: "field")

        #expect(attached?.focusedElement == nil)
    }

    @Test(arguments: [nil, "absent", "sibling"] as [String?])
    func `ordinary unique receipt wins over missing or conflicting corroboration`(hint: String?) throws {
        let elements = [self.element(id: "field"), self.element(id: "sibling", focused: false)]
        let expected = try FocusedElementReceiptResolver.uniqueReceipt(elements: elements, context: self.context())
        let attached = FocusedElementReceiptResolver.attachingObservedFocus(
            to: self.context(),
            elements: elements,
            corroboratedElementID: hint)

        #expect(attached?.focusedElement == expected)
        #expect(FocusedElementReceiptResolver.attachingObservedFocus(
            to: self.context(),
            elements: elements)?.focusedElement == expected)
    }

    @Test(arguments: InvalidCandidate.allCases)
    func `corroboration retains focus menu and geometry validation`(invalid: InvalidCandidate) {
        let candidate = self.element(
            id: "field",
            focused: invalid == .unknownFocus ? nil : invalid != .unfocused,
            frame: invalid == .emptyFrame ? .zero : invalid == .outsideWindow
                ? CGRect(x: 1, y: 1, width: 20, height: 20) : Self.fieldFrame,
            source: invalid == .menu ? DetectedElementRootPolicy.applicationMenuBarSource.uppercased() : nil)
        let elements = Array(self.ambiguousElements().prefix(2)) + [candidate]
        let attached = FocusedElementReceiptResolver.attachingObservedFocus(
            to: self.context(),
            elements: elements,
            corroboratedElementID: "field")

        #expect(attached?.focusedElement == nil)
    }

    @Test(arguments: InvalidContext.allCases)
    func `corroboration cannot manufacture missing process window or bounds`(invalid: InvalidContext) {
        let context = WindowContext(
            applicationProcessId: invalid == .missingProcess ? nil : invalid == .zeroProcess ? 0
                : invalid == .negativeProcess ? -1 : 700,
            windowID: invalid == .missingWindow ? nil : invalid == .zeroWindow ? 0
                : invalid == .negativeWindow ? -1 : 42,
            windowBounds: invalid == .missingBounds ? nil : invalid == .emptyBounds ? .zero : Self.bounds)
        let attached = FocusedElementReceiptResolver.attachingObservedFocus(
            to: context,
            elements: self.ambiguousElements(),
            corroboratedElementID: "field")

        #expect(attached?.focusedElement == nil)
    }

    @Test
    func `corroboration requires context and never invents explicit focus`() {
        #expect(FocusedElementReceiptResolver.attachingObservedFocus(
            to: nil,
            elements: self.ambiguousElements(),
            corroboratedElementID: "field") == nil)
        #expect(FocusedElementReceiptResolver.attachingObservedFocus(
            to: self.context(),
            elements: [self.element(id: "field", focused: false)],
            corroboratedElementID: "field")?.focusedElement == nil)
    }

    @Test(arguments: [CGRect.zero, CGRect(x: 1, y: 1, width: 20, height: 20)])
    func `invalid unique receipt does not fall back to a different hinted element`(frame: CGRect) {
        let elements = [
            self.element(id: "invalid", frame: frame),
            self.element(id: "field", focused: false),
        ]
        let attached = FocusedElementReceiptResolver.attachingObservedFocus(
            to: self.context(),
            elements: elements,
            corroboratedElementID: "field")

        #expect(attached?.focusedElement == nil)
    }

    @Test(arguments: [nil, DetectionTruncationInfo()] as [DetectionTruncationInfo?])
    func `fresh complete builder attaches corroboration and preserves emitted evidence`(
        truncation: DetectionTruncationInfo?) throws
    {
        let elements = self.ambiguousElements()
        let result = self.result(elements: elements, truncation: truncation)
        let receipt = try #require(result.metadata.windowContext?.focusedElement)

        #expect(receipt.identifier == "native-field")
        #expect(result.metadata.truncationInfo == truncation)
        #expect(result.metadata.elementCount == 3)
        #expect(result.elements.groups.count == 2)
        #expect(result.elements.textFields.count == 1)
        for element in elements {
            let emitted = try #require(result.elements.findById(element.id))
            #expect(emitted.attributes == element.attributes)
            #expect(emitted.bounds == element.bounds)
        }
    }

    @Test(arguments: SuppressedObservation.allCases)
    func `builder suppresses corroboration for cached partial and truncated observations`(
        observation: SuppressedObservation)
    {
        let result = self.result(
            elements: self.ambiguousElements(),
            usedCache: observation == .cached,
            truncation: observation.truncation,
            applicationFallback: observation == .applicationPartial)

        #expect(result.metadata.windowContext?.focusedElement == nil)
        #expect(result.metadata.windowContext?.applicationProcessStartIdentity == 99)
        #expect(result.elements.all.filter { $0.isFocused == true }.count == 3)
    }

    @Test(arguments: Self.truncations)
    func `truncated builder preserves ordinary unique focus behavior`(truncation: DetectionTruncationInfo) {
        let result = self.result(elements: [self.element(id: "field")], truncation: truncation)

        #expect(result.metadata.windowContext?.focusedElement?.identifier == "native-field")
        #expect(result.metadata.truncationInfo == truncation)
    }

    private func context() -> WindowContext {
        WindowContext(
            applicationName: "Synthetic Editor",
            applicationProcessId: 700,
            applicationProcessStartIdentity: 99,
            windowTitle: "Synthetic Document",
            windowID: 42,
            windowBounds: Self.bounds,
            windowMutationIdentity: self.windowIdentity(),
            focusedElement: FocusedElementIdentity(
                processIdentifier: 700,
                windowID: 42,
                role: "AXTextField",
                identifier: "stale-field",
                frame: Self.fieldFrame))
    }

    private func windowIdentity() -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 700,
            ownerProcessStartIdentity: 99,
            capturedBounds: Self.bounds)
    }

    private func ambiguousElements() -> [DetectedElement] {
        [
            self.element(id: "outer", type: .group, frame: CGRect(x: 120, y: 120, width: 700, height: 500)),
            self.element(id: "inner", type: .group, frame: CGRect(x: 130, y: 130, width: 400, height: 200)),
            self.element(id: "field"),
        ]
    }

    private func element(
        id: String,
        type: ElementType = .textField,
        focused: Bool? = true,
        frame: CGRect = Self.fieldFrame,
        source: String? = nil) -> DetectedElement
    {
        var attributes = ["role": type == .group ? "AXGroup" : "AXTextField", "identifier": "native-\(id)"]
        if let focused {
            attributes["isFocused"] = String(focused)
        }
        if let source {
            attributes[DetectedElementRootPolicy.sourceAttribute] = source
        }
        return DetectedElement(id: id, type: type, label: id, bounds: frame, attributes: attributes)
    }

    private func result(
        elements: [DetectedElement],
        usedCache: Bool = false,
        truncation: DetectionTruncationInfo? = nil,
        applicationFallback: Bool = false,
        corroboratedElementID: String? = "field") -> ElementDetectionResult
    {
        ElementDetectionResultBuilder.makeResult(
            snapshotId: "synthetic-observed-focus",
            elements: elements,
            usedCache: usedCache,
            windowContext: self.context(),
            isDialog: false,
            truncationInfo: truncation,
            applicationScopedAccessibilityFallbackOrigin: applicationFallback
                ? ApplicationScopedAccessibilityFallbackOrigin(windowIdentity: self.windowIdentity()) : nil,
            corroboratedFocusedElementID: corroboratedElementID)
    }

    enum EligibilityFailure: CaseIterable, Sendable {
        case incomplete, missingInitial, noCandidates, oneCandidate, expiredDeadline
    }

    enum DeadlineStage: CaseIterable, Sendable {
        case currentRead, correspondence, ownership
    }

    enum InvalidCandidate: CaseIterable, Sendable {
        case unfocused, unknownFocus, menu, emptyFrame, outsideWindow
    }

    enum InvalidContext: CaseIterable, Sendable {
        case missingProcess, zeroProcess, negativeProcess, missingWindow, zeroWindow, negativeWindow
        case missingBounds, emptyBounds
    }

    enum SuppressedObservation: CaseIterable, Sendable {
        case cached, applicationPartial, depth, count, children, deadline, incompleteRead

        var truncation: DetectionTruncationInfo? {
            switch self {
            case .cached, .applicationPartial: nil
            case .depth: DetectionTruncationInfo(maxDepthReached: true)
            case .count: DetectionTruncationInfo(maxElementCountReached: true)
            case .children: DetectionTruncationInfo(maxChildrenPerNodeReached: true)
            case .deadline: DetectionTruncationInfo(deadlineReached: true)
            case .incompleteRead: DetectionTruncationInfo(incompleteAccessibilityRead: true)
            }
        }
    }

    private struct Reference {
        let identity: Int
        let processIdentifier: Int32
        let windowID: Int
    }
}
