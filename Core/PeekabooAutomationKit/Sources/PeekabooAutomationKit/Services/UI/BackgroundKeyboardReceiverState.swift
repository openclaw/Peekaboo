import ApplicationServices
import Foundation
import PeekabooFoundation

/// Retains the editor, its exact UTF-16 contents and selection across internal key-window preparation.
/// This deliberately does not require the containing window to be the application's key window yet.
struct BackgroundKeyboardReceiverState: Sendable, Equatable {
    let snapshot: ExactWindowFocusSnapshot
    let selection: TextSelectionRange

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot.nativeElement == rhs.snapshot.nativeElement &&
            lhs.snapshot.processIdentifier == rhs.snapshot.processIdentifier &&
            lhs.snapshot.windowID == rhs.snapshot.windowID &&
            lhs.snapshot.frame == rhs.snapshot.frame &&
            lhs.snapshot.role == rhs.snapshot.role &&
            lhs.snapshot.subrole == rhs.snapshot.subrole &&
            lhs.snapshot.subroleIsReadable == rhs.snapshot.subroleIsReadable &&
            BackgroundInputDriver.exactTextMatches(lhs.snapshot.value, rhs.snapshot.value) &&
            lhs.selection == rhs.selection
    }

    static func read(
        expected: FocusedElementIdentity,
        retained: Self? = nil) throws -> Self
    {
        try self.read(
            snapshot: {
                try DetachedExactWindowFocusReader.readValue(
                    expected: expected, retainedElement: retained?.snapshot.nativeElement).get()
            },
            selection: { element in
                TextSelectionRange(nativeValue: DetachedExactWindowFocusReader.attribute(
                    kAXSelectedTextRangeAttribute, of: element.element,
                    deadline: ContinuousClock.now.advanced(by: .milliseconds(50))))
            },
            retained: retained)
    }

    static func read(
        snapshot: () throws -> ExactWindowFocusSnapshot,
        selection: (RetainedFocusElement) throws -> TextSelectionRange?,
        retained: Self?) throws -> Self
    {
        func sample() throws -> Self {
            let snapshot = try snapshot()
            guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(snapshot.role),
                  DetachedExactWindowFocusReader.allowsValueRead(snapshot),
                  let native = snapshot.nativeElement, let value = snapshot.value,
                  let selection = try selection(native),
                  selection.location + selection.length <= value.utf16.count
            else { throw Self.refusal() }
            return Self(snapshot: snapshot, selection: selection)
        }
        let before = try sample()
        let after = try sample()
        guard before == after, retained.map({ $0 == after }) ?? true else { throw Self.refusal() }
        return after
    }

    private static func refusal() -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: .targetUnavailable,
            message: "The exact background editor, UTF-16 text, or selection could not be retained unchanged.",
            hint: "Observe the target again; preparation never restores stale focus, text, or selection.")
    }
}
