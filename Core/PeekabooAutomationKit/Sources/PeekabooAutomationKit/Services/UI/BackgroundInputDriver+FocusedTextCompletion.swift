import Foundation
import PeekabooFoundation

extension BackgroundInputDriver {
    struct FocusedTextEditState: Equatable {
        let text: String?
        let selection: CFRange?

        static func == (lhs: Self, rhs: Self) -> Bool {
            BackgroundInputDriver.exactTextMatches(lhs.text, rhs.text) &&
                lhs.selection?.location == rhs.selection?.location &&
                lhs.selection?.length == rhs.selection?.length
        }
    }

    enum FocusedTextValueResult {
        case unsupported
        case noChange
        case accessibilityValue(FocusedTextEditState)
    }

    static func exactTextMatches(_ left: String?, _ right: String?) -> Bool {
        // AX ranges use UTF-16 offsets; canonical String equality is insufficient for focused text edits.
        switch (left, right) {
        case (nil, nil): true
        case let (.some(left), .some(right)): left.utf16.elementsEqual(right.utf16)
        default: false
        }
    }

    @MainActor
    static func performFocusedTextValueMutation(
        _ text: String,
        on element: any AutomationElementRepresenting,
        observer: ActionInputDriver,
        beforeMutation: @MainActor () throws -> Void,
        mutation: @MainActor () async throws -> FocusedTextKeyDispatch) async throws -> FocusedTextValueResult
    {
        var completionState: FocusedTextEditState?
        let dispatch = try await observer.performObservedMutation(
            on: element,
            attribute: .textSelection,
            beforeMutation: beforeMutation,
            mutation: mutation,
            matches: { sample in
                guard let sample, sample.focused == true,
                      case let .string(value)? = sample.value,
                      self.exactTextMatches(value, text),
                      let selection = sample.selectedTextRange,
                      selection.location <= value.utf16.count,
                      selection.length <= value.utf16.count - selection.location
                else { return false }
                // AXValue may itself move the caret. Freeze its confirmed result, never a later rebase.
                completionState = FocusedTextEditState(text: value, selection: selection.nativeRange)
                return true
            })
        switch dispatch {
        case .unsupported: return .unsupported
        case .noChange: return .noChange
        case .accessibilityValue:
            guard let completionState else {
                throw DesktopActionFailure.indeterminate(
                    delivery: .init(mechanism: .accessibilityValue, mode: .background),
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "The text value was written, but its completion state could not be confirmed.")
            }
            return .accessibilityValue(completionState)
        }
    }

    @MainActor
    static func completeTextEdit<Receiver>(
        _ range: CFRange,
        element: Receiver,
        valueDispatch: FocusedTextValueResult,
        sourceState: FocusedTextEditState,
        access: FocusedTextEditAccess<Receiver>) async throws -> FocusedTextKeyDispatch
    {
        let state: FocusedTextEditState
        let acceptedValue: Bool
        switch valueDispatch {
        case .unsupported: return .unsupported
        case .noChange:
            state = sourceState
            acceptedValue = false
        case let .accessibilityValue(completionState):
            state = completionState
            acceptedValue = true
        }
        do {
            try Task.checkCancellation()
            switch try await access.selectRange(range, element, state) {
            case .accessibilityValue:
                return .accessibilityValue
            case .noChange:
                return acceptedValue ? .accessibilityValue : .noChange
            case .unsupported:
                guard acceptedValue else { return .unsupported }
                throw ActionInputError.unsupported(.attributeUnsupported)
            }
        } catch {
            guard acceptedValue else { throw error }
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "The text value was written, but its selection could not be confirmed.",
                hint: "Observe the exact target before deciding whether to retry typing.",
                causeDescription: error.localizedDescription)
        }
    }
}
