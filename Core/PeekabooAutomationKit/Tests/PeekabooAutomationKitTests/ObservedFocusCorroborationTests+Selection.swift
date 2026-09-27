import Foundation
import PeekabooFoundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

extension ObservedFocusCorroborationTests {
    @Test(arguments: [false, true])
    func `one unique or corroborated focused receiver contributes one selection read`(corroborated: Bool) {
        let elements = corroborated ? self.ambiguousElements() : [self.element(id: "field")]
        let references = corroborated ? ["outer": 1, "inner": 2, "field": 3] : ["field": 3]
        var reads = 0
        let selected = DetachedAXObservationWorker.attachingFocusedTextSelection(
            observation: (
                elements: elements,
                references: references,
                corroboratedElementID: corroborated ? "field" : nil,
                isComplete: true),
            context: self.context(),
            deadline: .now.advanced(by: .seconds(1)),
            referencesEqual: ==,
            read: { reference, target, _ in
                #expect(reference == 3)
                #expect(target.processIdentifier == 700 && target.processStartIdentity == 99)
                reads += 1
                guard let identity = target.expectedIdentity else { return nil }
                return AXMutationObservationSnapshot(
                    identity: identity,
                    focused: true,
                    selectedTextRange: TextSelectionRange(location: 1, length: 2))
            })
        #expect(reads == 1)
        #expect(selected.first { $0.id == "field" }?.selectedTextRange == TextSelectionRange(location: 1, length: 2))
        #expect(selected.filter { $0.id != "field" }.allSatisfy { $0.selectedTextRange == nil })
        let result = self.result(elements: selected, corroboratedElementID: corroborated ? "field" : nil)
        #expect(result.elements.findById("field")?.selectedTextRange == TextSelectionRange(location: 1, length: 2))
        #expect(result.metadata.windowContext?.focusedElement?.identifier == "native-field")
    }

    @Test(arguments: SelectionRefusal.allCases)
    func `selection admission rejects incomplete expired and ambiguous receivers`(failure: SelectionRefusal) {
        var elements = [self.element(id: "field", focused: failure != .unfocused)]
        var references = ["field": 3]
        if failure == .missingReference {
            references = [:]
        }
        if failure == .ambiguous {
            references["other"] = 4
        }
        if failure == .duplicateReference {
            references["other"] = 3
        }
        if failure == .duplicateElement {
            elements.append(self.element(id: "field", focused: false))
        }
        let now = ContinuousClock.now
        var reads = 0
        let selected = DetachedAXObservationWorker.attachingFocusedTextSelection(
            observation: (
                elements: elements,
                references: references,
                corroboratedElementID: failure == .duplicateReference ? "field" : nil,
                isComplete: failure != .incomplete),
            context: self.context(),
            deadline: now.advanced(by: failure == .expired ? .milliseconds(-1) : .seconds(1)),
            now: { now },
            referencesEqual: ==,
            read: { _, _, _ in reads += 1; return nil })
        #expect(reads == 0)
        #expect(selected.allSatisfy { $0.selectedTextRange == nil })
    }

    @Test(arguments: [0.002, 0.05, 1.0], [false, true])
    func `optional selection shares a capped deadline and late data does not replace traversal`(
        remaining: Double,
        late: Bool)
    {
        let elements = [self.element(id: "field")]
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(remaining))
        var now = started
        var reads = 0
        let selected = DetachedAXObservationWorker.attachingFocusedTextSelection(
            observation: (
                elements: elements,
                references: ["field": 3],
                corroboratedElementID: nil,
                isComplete: true),
            context: self.context(),
            deadline: deadline,
            now: { now },
            referencesEqual: ==,
            read: { _, target, operationDeadline in
                reads += 1
                #expect(operationDeadline <= deadline)
                #expect(started.duration(to: operationDeadline) <= .milliseconds(51))
                if remaining == 0.05 {
                    #expect(started.duration(to: operationDeadline) < .milliseconds(13))
                }
                guard let identity = target.expectedIdentity else { return nil }
                if late {
                    now = operationDeadline
                }
                return AXMutationObservationSnapshot(
                    identity: identity,
                    focused: true,
                    selectedTextRange: TextSelectionRange(location: 4, length: 0))
            })
        #expect(reads == (remaining == 0.002 ? 0 : 1))
        #expect((selected.first?.selectedTextRange != nil) == (!late && remaining != 0.002))
        #expect(selected.first?.id == elements.first?.id)
        #expect(selected.first?.bounds == elements.first?.bounds)
    }

    @Test(arguments: SuppressedObservation.allCases)
    func `cached partial and truncated output drops selection without tightening ordinary focus`(
        observation: SuppressedObservation)
    {
        let selected = self.element(id: "field").replacingSelectedTextRange(TextSelectionRange(location: 1, length: 2))
        let result = self.result(
            elements: [selected],
            usedCache: observation == .cached,
            truncation: observation.truncation,
            applicationFallback: observation == .applicationPartial)
        #expect(result.elements.findById("field")?.selectedTextRange == nil)
        #expect(result.elements.findById("field")?.attributes["selectedTextRangeLocation"] == nil)
        #expect(result.elements.findById("field")?.isFocused == true)
        #expect((result.metadata.windowContext?.focusedElement == nil) ==
            (observation == .cached || observation == .applicationPartial))
    }

    enum SelectionRefusal: CaseIterable {
        case incomplete, expired, ambiguous, duplicateReference, duplicateElement, missingReference, unfocused
    }
}
