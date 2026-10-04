import ApplicationServices
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct TextSelectionRequestTests {
    @Test
    func `out of range caret evidence is rejected without arithmetic traps`() throws {
        let range = try #require(TextSelectionRange(location: Int.max - 1, length: 1))
        #expect(TextSelectionResult(matchedRange: range, selectionType: .cursorAfter) == nil)
    }

    @Test(arguments: TextSelectionType.allCases)
    func `literal selection uses UTF16 and immediate context`(mode: TextSelectionType) throws {
        let result = try TextSelectionRequest(
            text: "🦞", prefix: "B ", suffix: "!", selectionType: mode).resolve(in: "A 🦞? B 🦞!")
        #expect(result.matchedRange == TextSelectionRange(location: 8, length: 2))
        #expect(result.selectedRange == TextSelectionRange(
            location: mode == .cursorAfter ? 10 : 8, length: mode == .text ? 2 : 0))
    }

    @Test
    func `missing ambiguous overlapping and empty literals refuse`() {
        for request in [
            TextSelectionRequest(text: ""), TextSelectionRequest(text: "missing"),
            TextSelectionRequest(text: "aa"), TextSelectionRequest(text: "a", prefix: "missing"),
        ] {
            #expect(throws: PeekabooError.self) { try request.resolve(in: "aaa") }
        }
    }

    @Test
    func `literal matching and source equality do not normalize Unicode`() throws {
        #expect("é" == "e\u{301}")
        #expect(throws: PeekabooError.self) { try TextSelectionRequest(text: "é").resolve(in: "e\u{301}") }
        #expect(try TextSelectionRequest(text: "X").resolve(in: "e\u{301}X").matchedRange.location == 2)
        let range = try #require(TextSelectionRange(location: 0, length: 0))
        #expect(TextSelectionState(text: "é", range: range) != TextSelectionState(text: "e\u{301}", range: range))
    }
}

@MainActor
struct TextSelectionMutationTests {
    @Test(arguments: [false, true])
    func `window authority revoked during final text read refuses both writes and no ops`(noChange: Bool) async throws {
        let field = ActionInputMockAutomationElement(
            underlyingAXElement: AXUIElementCreateApplication(777),
            role: "AXTextArea",
            frame: CGRect(x: 10, y: 10, width: 200, height: 100),
            value: "é target")
        field.isTextSelectionSettable = true
        let range = try #require(TextSelectionRange(location: noChange ? 2 : 0, length: noChange ? 6 : 0))
        field.textSelectionRange = range
        let identity = try #require(field.focusedElementIdentity)
        let authority = TextSelectionAuthorityFixture()
        let driver = ActionInputDriver(
            observationDelay: {},
            processStartIdentity: { _ in 1 },
            nativeReader: { _, _, attribute, _ in
                if attribute == .identity {
                    return AXMutationObservationSnapshot(identity: identity)
                }
                return await MainActor.run {
                    authority.textReads += 1
                    if authority.textReads == 2 {
                        authority.isCurrent = false
                    }
                    return AXMutationObservationSnapshot(
                        identity: identity, value: .string("é target"), selectedTextRange: range)
                }
            })
        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await driver.selectText(element: field, request: .init(text: "target"), beforeMutation: {
                guard authority.isCurrent else {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .targetUnavailable, message: "Observed window bounds changed")
                }
            })
        }
        #expect(authority.textReads == 2)
        #expect(failure?.outcome.retrySafety == .safe)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(field.selectionWrites.isEmpty)
    }

    @Test
    func `source read errors are retry safe before selection dispatch`() async throws {
        let field = ActionInputMockAutomationElement(
            underlyingAXElement: AXUIElementCreateApplication(777),
            role: "AXTextArea",
            frame: CGRect(x: 10, y: 10, width: 200, height: 100),
            value: "é target")
        field.isTextSelectionSettable = true
        field.textSelectionRange = TextSelectionRange(location: 0, length: 0)
        let identity = try #require(field.focusedElementIdentity)
        let driver = ActionInputDriver(
            observationDelay: {},
            processStartIdentity: { _ in 1 },
            nativeReader: { _, _, attribute, _ in
                if attribute == .identity {
                    return AXMutationObservationSnapshot(identity: identity)
                }
                throw CocoaError(.fileReadUnknown)
            })
        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await driver.selectText(element: field, request: .init(text: "target"))
        }
        #expect(failure?.outcome.retrySafety == .safe)
        #expect(failure?.outcome.refusalReason == .targetUnavailable)
        #expect(field.selectionWrites.isEmpty)
    }

    @Test(arguments: ["missing", ""])
    func `unmatched or empty text reports a retry safe refusal`(text: String) async throws {
        let field = self.field()
        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await ActionInputDriver(observationDelay: {}).selectText(element: field, request: .init(text: text))
        }
        #expect(failure?.outcome.refusalReason == .invalidRequest)
        #expect(failure?.outcome.retrySafety == .safe)
        #expect(field.selectionWrites.isEmpty)
    }

    @Test
    func `secure targets and receiver revocation never write`() async throws {
        let secure = ActionInputMockAutomationElement(role: "AXSecureTextField", value: "synthetic password")
        secure.isTextSelectionSettable = true
        let secureFailure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await ActionInputDriver().selectText(element: secure, request: .init(text: "password"))
        }
        #expect(secureFailure?.outcome.retrySafety == .safe)
        #expect(secure.selectionWrites.isEmpty)
        let field = self.field()
        var checks = 0
        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await ActionInputDriver().selectText(
                element: field,
                request: .init(text: "target"),
                beforeMutation: {
                    checks += 1
                    if checks == 2 {
                        throw DesktopActionFailure.preDispatchRefusal(
                            reason: .targetUnavailable, message: "Receiver changed")
                    }
                })
        }
        #expect(failure?.outcome.retrySafety == .safe)
        #expect(field.selectionWrites.isEmpty)
    }

    @Test(arguments: TextSelectionType.allCases)
    func `unfocused nonwritable values permit selection without editing or focusing`(
        mode: TextSelectionType) async throws
    {
        let field = self.field()
        let guardField = self.field()
        let before = field.stringValue
        let (action, result) = try await ActionInputDriver(observationDelay: {}).selectText(
            element: field, request: .init(text: "target", selectionType: mode))
        #expect(action.outcome.state == .confirmedChange)
        #expect(field.selectionWrites == [result.selectedRange])
        #expect(field.stringValue == before)
        #expect(!field.isValueSettable && !field.isFocused)
        #expect(field.setValues.isEmpty && field.setFocusedValues.isEmpty && field.performedActions.isEmpty)
        #expect(guardField.selectionWrites.isEmpty && guardField.stringValue == before)
    }

    @Test
    func `an already selected range is a zero write no op`() async throws {
        let field = self.field()
        field.textSelectionRange = TextSelectionRange(location: 2, length: 6)
        let (action, _) = try await ActionInputDriver(observationDelay: {}).selectText(
            element: field, request: .init(text: "target"))
        #expect(action.outcome.state == .confirmedNoChange)
        #expect(field.selectionWrites.isEmpty)
    }

    @Test(arguments: [false, true])
    func `source or selection drift refuses before the write`(selectionDrift: Bool) async throws {
        let field = self.field()
        var checks = 0
        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await ActionInputDriver(observationDelay: {}).selectText(
                element: field, request: .init(text: "target"), beforeMutation: {
                    checks += 1
                    if checks == 2 {
                        if selectionDrift {
                            field.textSelectionRange = TextSelectionRange(location: 1, length: 0)
                        } else {
                            field.value = "e\u{301} target"
                        }
                    }
                })
        }
        #expect(failure?.outcome.retrySafety == .safe)
        #expect(field.selectionWrites.isEmpty)
    }

    @Test(arguments: [false, true])
    func `accepted writes with unconfirmed range or changed text are never replayed`(changesText: Bool) async throws {
        let field = self.field()
        field.selectionWrite = { range in
            if changesText {
                field.textSelectionRange = range
                field.value = "e\u{301} target"
            }
            return true
        }
        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await ActionInputDriver(observationDelay: {}).selectText(
                element: field, request: .init(text: "target"))
        }
        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.retrySafety == .unsafe)
        #expect(field.selectionWrites.count == 1)
        #expect(field.setValues.isEmpty && field.setFocusedValues.isEmpty && field.performedActions.isEmpty)
    }

    private func field() -> ActionInputMockAutomationElement {
        let field = ActionInputMockAutomationElement(role: "AXTextArea", value: "é target")
        field.isTextSelectionSettable = true
        field.textSelectionRange = TextSelectionRange(location: 0, length: 0)
        return field
    }
}

@MainActor
private final class TextSelectionAuthorityFixture {
    var textReads = 0
    var isCurrent = true
}
