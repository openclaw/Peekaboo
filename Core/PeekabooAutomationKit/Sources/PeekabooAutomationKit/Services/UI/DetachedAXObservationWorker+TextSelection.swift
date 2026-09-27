import ApplicationServices
import Foundation
import PeekabooFoundation

extension DetachedAXObservationWorker {
    static func attachingFocusedTextSelection(
        observation: (
            elements: [DetectedElement], references: [String: AXUIElement],
            corroboratedElementID: String?, isComplete: Bool),
        request: DetachedAXObservationRequest,
        deadline: ContinuousClock.Instant) -> [DetectedElement]
    {
        guard let windowID = request.windowID, let bounds = request.expectedWindowBounds,
              request.windowMutationIdentity != nil else { return observation.elements }
        return self.attachingFocusedTextSelection(
            observation: observation,
            context: WindowContext(
                applicationProcessId: request.processIdentifier,
                applicationProcessStartIdentity: request.expectedProcessStartIdentity,
                windowID: windowID,
                windowBounds: bounds),
            deadline: deadline,
            referencesEqual: { CFEqual($0, $1) },
            read: { element, target, deadline in
                DetachedAXMutationReader.readSynchronously(
                    element: RetainedFocusElement(element: element),
                    target: target,
                    attribute: .selectedTextRange,
                    deadline: deadline,
                    requiresFocusedReceiver: true)
            })
    }

    static func attachingFocusedTextSelection<Reference>(
        observation: (
            elements: [DetectedElement],
            references: [String: Reference],
            corroboratedElementID: String?,
            isComplete: Bool),
        context: WindowContext,
        deadline: ContinuousClock.Instant,
        now: () -> ContinuousClock.Instant = { .now },
        referencesEqual: (Reference, Reference) -> Bool,
        read: (Reference, AXMutationObservationTarget, ContinuousClock.Instant) -> AXMutationObservationSnapshot?)
        -> [DetectedElement]
    {
        let (elements, references, corroboratedElementID, isComplete) = observation
        guard isComplete, let generation = context.applicationProcessStartIdentity, generation > 0,
              let elementID = references.count == 1 ? references.first?.key : corroboratedElementID,
              let reference = references[elementID],
              references.values.filter({ referencesEqual($0, reference) }).count == 1
        else { return elements }
        let matches = elements.indices.filter { elements[$0].id == elementID }
        guard matches.count == 1, let index = matches.first,
              elements[index].type == .textField, elements[index].isFocused == true,
              elements[index].attributes["role"] != "AXSecureTextField",
              elements[index].attributes[DetectedElementRootPolicy.sourceAttribute]?
                  .caseInsensitiveCompare(DetectedElementRootPolicy.applicationMenuBarSource) != .orderedSame,
                  let expected = try? FocusedElementReceiptResolver.receipt(element: elements[index], context: context)
        else { return elements }

        let started = now()
        let observed = self.initialFocusedReference(deadline: deadline, now: started) { timeout in
            let selectionDeadline = min(deadline, started.advanced(by: .seconds(Double(timeout))))
            let target = AXMutationObservationTarget(
                processIdentifier: expected.processIdentifier,
                processStartIdentity: generation,
                expectedIdentity: expected)
            guard now() < selectionDeadline,
                  let snapshot = read(reference, target, selectionDeadline), now() < selectionDeadline,
                  snapshot.focused == true,
                  FocusedElementReceiptResolver.matches(snapshot.identity, expected: expected),
                  let range = snapshot.selectedTextRange
            else { return nil as (range: TextSelectionRange, deadline: ContinuousClock.Instant)? }
            return (range: range, deadline: selectionDeadline)
        }
        guard let observed else { return elements }
        var result = elements
        result[index] = result[index].replacingSelectedTextRange(observed.range)
        return now() < observed.deadline ? result : elements
    }
}
