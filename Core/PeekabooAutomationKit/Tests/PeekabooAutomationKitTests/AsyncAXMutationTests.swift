import AppKit
import ApplicationServices
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct AsyncAXMutationTests {
    enum NativeMutation: CaseIterable {
        case value, focus
    }

    enum NativeObservation: CaseIterable {
        case timeout, transientMissing, authorityRevoked
    }

    @Test(arguments: NativeMutation.allCases, NativeObservation.allCases)
    func `native mutation preserves authority and bounded observation outcomes`(
        mutation: NativeMutation,
        observation: NativeObservation) async throws
    {
        let authorityRevoked = observation == .authorityRevoked
        let native = AXUIElementCreateApplication(getpid())
        let reference = RetainedFocusElement(element: native)
        let identity = FocusedElementIdentity(
            processIdentifier: getpid(),
            windowID: 42,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 1, y: 2, width: 100, height: 20))
        let element = ActionInputMockAutomationElement(
            underlyingAXElement: native,
            identifier: "editor",
            role: identity.role,
            frame: identity.frame,
            value: "before",
            isValueSettable: true,
            isFocusedSettable: true,
            focusedElementIdentity: identity)
        var postDispatchSamples = 0
        var sampleDelays = 0
        var captureCompleted = false
        var authorityChecks = 0
        let driver = ActionInputDriver(
            observationDelay: {
                sampleDelays += 1
                #expect(observation == .transientMissing)
            },
            processStartIdentity: { _ in 1 },
            nativeReader: { retained, target, _, timeout in
                try await MainActor.run {
                    #expect(retained == reference)
                    #expect(target.processIdentifier == identity.processIdentifier)
                    #expect(target.processStartIdentity == 1)
                    #expect(timeout > .zero && timeout <= .milliseconds(250))
                    guard element.setValues.isEmpty, element.setFocusedValues.isEmpty else {
                        postDispatchSamples += 1
                        if observation == .transientMissing {
                            guard postDispatchSamples > 1 else { return nil }
                            return AXMutationObservationSnapshot(
                                identity: identity,
                                focused: true,
                                value: .string("after"),
                                legacyPresentation: "after")
                        }
                        // The detached reader's exhausted-deadline result must not fall back to
                        // synchronous attributes, even though this fixture already exposes the change.
                        throw CaptureError.detectionTimedOut(0.25)
                    }
                    captureCompleted = true
                    return AXMutationObservationSnapshot(identity: identity)
                }
            })
        let beforeMutation: @MainActor () throws -> Void = {
            #expect(captureCompleted)
            authorityChecks += 1
            if authorityRevoked {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "The captured target lost mutation authority.")
            }
        }

        let performMutation: @MainActor () async throws -> UIInputExecutionResult.Action = {
            switch mutation {
            case .value:
                try await driver.trySetValueForTesting(
                    element: element, value: .string("after"), beforeMutation: beforeMutation)
            case .focus:
                try await driver.tryFocus(element: element, beforeMutation: beforeMutation)
            }
        }

        if observation == .transientMissing {
            let result = try await performMutation()
            #expect(result.outcome.state == .confirmedChange)
        } else {
            let failure = await #expect(throws: DesktopActionFailure.self) { try await performMutation() }
            #expect(failure?.outcome.state == (authorityRevoked ? .refused : .indeterminate))
            #expect(failure?.outcome.retrySafety == (authorityRevoked ? .safe : .unsafe))
            if authorityRevoked {
                #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            } else {
                #expect(failure?.outcome.dispatchState.unitCount == .one)
            }
        }
        #expect(authorityChecks == 1)
        #expect(postDispatchSamples == (authorityRevoked ? 0 : observation == .transientMissing ? 2 : 1))
        #expect(sampleDelays == (observation == .transientMissing ? 1 : 0))
        #expect(element.setValues == (mutation == .value && !authorityRevoked ? [.string("after")] : []))
        #expect(element.setFocusedValues == (mutation == .focus && !authorityRevoked ? [true] : []))
    }

    @Test
    func `queued value write is verified on the same field after layout reflow`() async throws {
        let element = ActionInputMockAutomationElement(
            role: "AXTextField",
            frame: CGRect(x: 1, y: 2, width: 100, height: 20),
            value: "before",
            isValueSettable: true,
            valueSetterDoesNotChange: true)
        var observations = 0
        let driver = ActionInputDriver(observationDelay: {
            observations += 1
            if observations == 2 {
                element.value = "after"
            }
        }, processStartIdentity: { _ in 1 })

        let result = try await driver.trySetValueForTesting(element: element, value: .string("after"))

        #expect(result.outcome.state == .confirmedChange)
        #expect(result.valueVerification?.readback == .string("after"))
        #expect(element.setValues == [.string("after")])
        #expect(observations == 2)
    }

    @Test
    func `queued focus is verified on the same field without another dispatch`() async throws {
        let element = ActionInputMockAutomationElement(
            role: "AXTextField",
            frame: CGRect(x: 1, y: 2, width: 100, height: 20),
            isValueSettable: true,
            isFocusedSettable: true,
            focusSetterDoesNotChange: true)
        let driver = ActionInputDriver(observationDelay: {
            element.isFocused = true
        }, processStartIdentity: { _ in 1 })

        let result = try await driver.tryClickForTesting(element: element)

        #expect(result.outcome.state == .confirmedChange)
        #expect(result.focusedElement == element.focusedElementIdentity)
        #expect(element.setFocusedValues == [true])
    }

    @Test
    func `generation change cannot confirm even when requested value appears`() async throws {
        let element = ActionInputMockAutomationElement(
            role: "AXTextField",
            frame: CGRect(x: 1, y: 2, width: 100, height: 20),
            value: "before",
            isValueSettable: true,
            valueSetterDoesNotChange: true)
        let generations = ProcessGenerationReadSequence([1, 1, 1, 2])
        let driver = ActionInputDriver(observationDelay: {
            element.value = "after"
        }, processStartIdentity: { _ in generations.next() })

        let failure = await #expect(throws: DesktopActionFailure.self) {
            try await driver.trySetValueForTesting(element: element, value: .string("after"))
        }

        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.retrySafety == .unsafe)
        #expect(element.setValues == [.string("after")])
    }

    @Test
    func `unconfirmed asynchronous write terminates without retrying`() async throws {
        let element = ActionInputMockAutomationElement(
            role: "AXTextField",
            frame: CGRect(x: 1, y: 2, width: 100, height: 20),
            value: "before",
            isValueSettable: true,
            valueSetterDoesNotChange: true)
        var observations = 0
        let driver = ActionInputDriver(observationDelay: {
            observations += 1
        }, processStartIdentity: { _ in 1 })

        let failure = await #expect(throws: DesktopActionFailure.self) {
            try await driver.trySetValueForTesting(element: element, value: .string("after"))
        }

        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.retrySafety == .unsafe)
        #expect(observations > 0 && observations < 20)
        #expect(element.setValues == [.string("after")])
    }

    @Test
    func `cancelled observation preserves accepted write uncertainty`() async throws {
        let element = ActionInputMockAutomationElement(
            role: "AXTextField",
            frame: CGRect(x: 1, y: 2, width: 100, height: 20),
            value: "before",
            isValueSettable: true,
            valueSetterDoesNotChange: true)
        let driver = ActionInputDriver(observationDelay: {
            throw CancellationError()
        }, processStartIdentity: { _ in 1 })

        let failure = await #expect(throws: DesktopActionFailure.self) {
            try await driver.trySetValueForTesting(element: element, value: .string("after"))
        }

        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.retrySafety == .unsafe)
        #expect(element.setValues == [.string("after")])
    }
}
