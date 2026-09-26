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

    enum CancellationMutation: CaseIterable {
        case value, focus, selected, observedValue
    }

    enum PressCancellationBoundary: CaseIterable {
        case beforeCall, beforeMutation
    }

    enum NativeReadCompletion: CaseIterable, Sendable {
        case sample, missing, failure, cancellation

        func result(identity: FocusedElementIdentity) throws -> AXMutationObservationSnapshot? {
            switch self {
            case .sample:
                AXMutationObservationSnapshot(
                    identity: identity,
                    focused: true,
                    value: .string("after"),
                    legacyPresentation: "after",
                    selected: true)
            case .missing:
                nil
            case .failure:
                throw CaptureError.detectionTimedOut(0.25)
            case .cancellation:
                throw CancellationError()
            }
        }
    }

    @Test(arguments: PressCancellationBoundary.allCases)
    func `cancelled press never dispatches an action or fallback mutation`(boundary: PressCancellationBoundary) async {
        let element = ActionInputMockAutomationElement(
            role: "AXTextField",
            actionNames: ["AXPress"],
            isValueSettable: true,
            isFocusedSettable: true,
            isSelectedSettable: true)
        var authorityChecks = 0
        let task = Task {
            if boundary == .beforeCall {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            _ = try await ActionInputDriver().tryClickForTesting(element: element) {
                authorityChecks += 1
                if boundary == .beforeMutation {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(authorityChecks == (boundary == .beforeCall ? 0 : 1))
        #expect(element.attemptedActions.isEmpty)
        #expect(element.performedActions.isEmpty)
        #expect(element.setValues.isEmpty)
        #expect(element.setFocusedValues.isEmpty)
        #expect(element.setSelectedValues.isEmpty)
    }

    @Test
    func `uncancelled press dispatches exactly one action after authority validation`() async throws {
        let element = ActionInputMockAutomationElement(
            role: "AXButton",
            actionNames: ["AXPress"])
        var authorityChecks = 0

        let result = try await ActionInputDriver().tryClickForTesting(element: element) {
            authorityChecks += 1
            #expect(element.attemptedActions.isEmpty)
        }

        #expect(authorityChecks == 1)
        #expect(element.attemptedActions == ["AXPress"])
        #expect(element.performedActions == ["AXPress"])
        #expect(element.setValues.isEmpty)
        #expect(element.setFocusedValues.isEmpty)
        #expect(element.setSelectedValues.isEmpty)
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.evidence == .deliveryAccepted)
        #expect(result.outcome.dispatchState.unitCount == .one)
    }

    @Test
    func `non-press actions retain direct dispatch`() throws {
        let element = ActionInputMockAutomationElement(actionNames: ["AXIncrement"])

        let result = try ActionInputDriver().tryPerformActionForTesting(element: element, actionName: "AXIncrement")

        #expect(element.attemptedActions == ["AXIncrement"])
        #expect(element.performedActions == ["AXIncrement"])
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.dispatchState.unitCount == .one)
    }

    @Test(arguments: CancellationMutation.allCases, NativeReadCompletion.allCases)
    func `cancelled initial native observation never dispatches its late result`(
        mutation: CancellationMutation,
        completion: NativeReadCompletion) async throws
    {
        let element = Self.nativeElement(for: mutation)
        let identity = try #require(element.focusedElementIdentity)
        let entered = ActionLaneLatch()
        let release = ActionLaneLatch()
        var authorityChecks = 0
        let driver = ActionInputDriver(processStartIdentity: { _ in 1 }, nativeReader: { _, target, _, _ in
            #expect(target.expectedIdentity == nil)
            await entered.open()
            await release.wait()
            return try completion.result(identity: identity)
        })
        let task = Task {
            try await Self.performNativeMutation(mutation, element: element, driver: driver) {
                authorityChecks += 1
            }
        }

        await entered.wait()
        task.cancel()
        await release.open()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(authorityChecks == 0)
        #expect(element.setValues.isEmpty)
        #expect(element.setFocusedValues.isEmpty)
        #expect(element.setSelectedValues.isEmpty)
    }

    @Test(arguments: CancellationMutation.allCases)
    func `native reader cancellation propagates without a cancelled task`(mutation: CancellationMutation) async {
        let element = Self.nativeElement(for: mutation)
        var authorityChecks = 0
        let driver = ActionInputDriver(processStartIdentity: { _ in 1 }, nativeReader: { _, _, _, _ in
            #expect(!Task.isCancelled)
            throw CancellationError()
        })

        #expect(!Task.isCancelled)
        await #expect(throws: CancellationError.self) {
            try await Self.performNativeMutation(mutation, element: element, driver: driver) {
                authorityChecks += 1
            }
        }

        #expect(!Task.isCancelled)
        #expect(authorityChecks == 0)
        #expect(element.setValues.isEmpty)
        #expect(element.setFocusedValues.isEmpty)
        #expect(element.setSelectedValues.isEmpty)
    }

    @Test(arguments: CancellationMutation.allCases, [false, true])
    func `final authority callback cancellation prevents native mutation`(
        mutation: CancellationMutation,
        cancelBeforeMutation: Bool) async throws
    {
        let element = Self.nativeElement(for: mutation)
        let identity = try #require(element.focusedElementIdentity)
        var authorityChecks = 0
        let driver = ActionInputDriver(processStartIdentity: { _ in 1 }, nativeReader: { _, target, _, _ in
            if target.expectedIdentity == nil {
                return AXMutationObservationSnapshot(identity: identity)
            }
            return try NativeReadCompletion.sample.result(identity: identity)
        })
        let task = Task {
            try await Self.performNativeMutation(mutation, element: element, driver: driver) {
                authorityChecks += 1
                #expect(element.setValues.isEmpty)
                #expect(element.setFocusedValues.isEmpty)
                #expect(element.setSelectedValues.isEmpty)
                if cancelBeforeMutation {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }

        if cancelBeforeMutation {
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(element.setValues.isEmpty)
            #expect(element.setFocusedValues.isEmpty)
            #expect(element.setSelectedValues.isEmpty)
        } else {
            try await task.value
            Self.expectSingleWrite(mutation, element: element)
        }
        #expect(authorityChecks == 1)
        #expect(element.attemptedActions.isEmpty)
        #expect(element.performedActions.isEmpty)
    }

    @Test(arguments: CancellationMutation.allCases, NativeReadCompletion.allCases)
    func `cancelled native readback retains exactly one accepted write`(
        mutation: CancellationMutation,
        completion: NativeReadCompletion) async throws
    {
        let element = Self.nativeElement(for: mutation)
        let identity = try #require(element.focusedElementIdentity)
        let entered = ActionLaneLatch()
        let release = ActionLaneLatch()
        let driver = ActionInputDriver(processStartIdentity: { _ in 1 }, nativeReader: { _, target, _, _ in
            guard target.expectedIdentity != nil else {
                return AXMutationObservationSnapshot(identity: identity)
            }
            await entered.open()
            await release.wait()
            return try completion.result(identity: identity)
        })
        let task = Task {
            try await Self.performNativeMutation(mutation, element: element, driver: driver)
        }

        await entered.wait()
        task.cancel()
        await release.open()

        let failure = await #expect(throws: DesktopActionFailure.self) { try await task.value }
        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.retrySafety == .unsafe)
        #expect(failure?.outcome.dispatchState.unitCount == .one)
        Self.expectSingleWrite(mutation, element: element)
    }

    @Test(arguments: CancellationMutation.allCases)
    func `uncancelled suspended native observation still dispatches once`(mutation: CancellationMutation) async throws {
        let element = Self.nativeElement(for: mutation)
        let identity = try #require(element.focusedElementIdentity)
        let entered = ActionLaneLatch()
        let release = ActionLaneLatch()
        let driver = ActionInputDriver(processStartIdentity: { _ in 1 }, nativeReader: { _, target, _, _ in
            if target.expectedIdentity == nil {
                await entered.open()
                await release.wait()
            }
            return try NativeReadCompletion.sample.result(identity: identity)
        })
        let task = Task {
            try await Self.performNativeMutation(mutation, element: element, driver: driver)
        }

        await entered.wait()
        await release.open()
        try await task.value

        Self.expectSingleWrite(mutation, element: element)
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
    func `queued value write is verified on the same field after delayed settlement`() async throws {
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

    private static func nativeElement(for mutation: CancellationMutation) -> ActionInputMockAutomationElement {
        let identity = FocusedElementIdentity(
            processIdentifier: getpid(),
            windowID: 42,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 1, y: 2, width: 100, height: 20))
        return ActionInputMockAutomationElement(
            underlyingAXElement: AXUIElementCreateApplication(getpid()),
            identifier: "editor",
            role: identity.role,
            frame: identity.frame,
            value: "before",
            isValueSettable: mutation != .selected,
            isFocusedSettable: true,
            isSelectedSettable: mutation == .selected,
            selectedValue: false,
            focusedElementIdentity: identity)
    }

    private static func performNativeMutation(
        _ mutation: CancellationMutation,
        element: ActionInputMockAutomationElement,
        driver: ActionInputDriver,
        beforeMutation: @MainActor () throws -> Void = {}) async throws
    {
        switch mutation {
        case .value:
            _ = try await driver.trySetValueForTesting(
                element: element, value: .string("after"), beforeMutation: beforeMutation)
        case .focus:
            _ = try await driver.tryFocus(element: element, beforeMutation: beforeMutation)
        case .selected:
            _ = try await driver.trySetValueForTesting(
                element: element, value: .bool(true), beforeMutation: beforeMutation)
        case .observedValue:
            _ = try await driver.performObservedMutation(
                on: element,
                attribute: .value,
                beforeMutation: beforeMutation,
                mutation: {
                    try element.setAutomationValue(.string("after"))
                    return .accessibilityValue
                }, matches: { $0?.value == .string("after") })
        }
    }

    private static func expectSingleWrite(
        _ mutation: CancellationMutation,
        element: ActionInputMockAutomationElement)
    {
        #expect(element.setValues == (mutation == .value || mutation == .observedValue ? [.string("after")] : []))
        #expect(element.setFocusedValues == (mutation == .focus ? [true] : []))
        #expect(element.setSelectedValues == (mutation == .selected ? [true] : []))
    }
}
