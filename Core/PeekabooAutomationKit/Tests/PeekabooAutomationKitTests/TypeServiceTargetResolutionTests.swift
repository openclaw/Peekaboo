import CoreGraphics
import Foundation
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

struct TypeServiceTargetResolutionTests {
    @Test
    func `legacy type result decodes without special key event count`() throws {
        let data = Data(#"{"totalCharacters":1,"keyPresses":1}"#.utf8)
        let result = try JSONDecoder().decode(TypeResult.self, from: data)

        #expect(result.totalCharacters == 1)
        #expect(result.keyPresses == 1)
        #expect(result.specialKeyPresses == nil)
    }

    @Test
    func `targeted printable characters preserve their exact Unicode payload`() throws {
        let targetPID: pid_t = 4242
        let characters: [Character] = ["y", "z", "&", "|", "-", "\"", "ä"]

        for character in characters {
            let events = try BackgroundInputDriver.unicodeKeyboardEvents(
                for: character,
                targetProcessIdentifier: targetPID)

            #expect(Self.unicodeString(from: events.keyDown) == String(character))
            #expect(Self.unicodeString(from: events.keyUp) == String(character))
            #expect(events.keyDown.getIntegerValueField(.eventTargetUnixProcessID) == Int64(targetPID))
            #expect(events.keyUp.getIntegerValueField(.eventTargetUnixProcessID) == Int64(targetPID))
        }
    }

    @Test
    @MainActor
    func `exact window delivery revalidates before every targeted character`() async throws {
        var typed: [Character] = []
        var validationCount = 0
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            targetedCharacterTyper: { character, _, delivery in
                typed.append(character)
                return .dispatched(delivery: delivery, keyPressCount: 1)
            })

        do {
            _ = try await service.typeActionsTrackingSecureInput(
                [.text("ab")],
                cadence: .fixed(milliseconds: 0),
                snapshotId: nil,
                targetProcessIdentifier: 4242,
                deliveryValidator: {
                    validationCount += 1
                    if validationCount == 2 {
                        throw PeekabooError.invalidInput("focus changed")
                    }
                })
            Issue.record("Expected focus revalidation to stop the second character")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .type)
            #expect(error.emittedUnitCount == 1)
            #expect(error.operationMayHaveCompleted)
            #expect(!error.retrySafe)
            #expect(error.localizedDescription.contains("focus changed"))
        } catch {
            Issue.record("Expected indeterminate delivery error, got \(error)")
        }

        #expect(validationCount == 2)
        #expect(typed == ["a"])
    }

    @Test
    @MainActor
    func `final character drift is retry unsafe instead of exact success`() async throws {
        var destinationIsValid = true
        var typed: [Character] = []
        var validationCount = 0
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            targetedCharacterTyper: { character, _, delivery in
                typed.append(character)
                destinationIsValid = false
                return .dispatched(delivery: delivery, keyPressCount: 1)
            })

        do {
            _ = try await service.typeActionsTrackingSecureInput(
                [.text("a")],
                cadence: .fixed(milliseconds: 0),
                snapshotId: nil,
                targetProcessIdentifier: 4242,
                deliveryValidator: {
                    validationCount += 1
                    guard destinationIsValid else {
                        throw TypeDeliveryTestError.destinationDrifted
                    }
                })
            Issue.record("Expected final character validation to fail")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .type)
            #expect(error.emittedUnitCount == 1)
            #expect(error.operationMayHaveCompleted)
            #expect(!error.retrySafe)
            #expect(error.causeDescription?.contains("destination drifted") == true)
        } catch {
            Issue.record("Expected indeterminate delivery error, got \(error)")
        }

        #expect(validationCount == 2)
        #expect(typed == ["a"])
    }

    @Test
    @MainActor
    func `keyboard outcomes preserve process and exact window routes`() async throws {
        let processIdentifier = getpid()
        let generation: UInt64 = 91
        let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        let process = try UIAutomationTarget.process(.init(
            processIdentifier: processIdentifier,
            identity: ApplicationProcessIdentity(
                processIdentifier: processIdentifier,
                processStartIdentity: generation)))
        let exactWindow = try UIAutomationTarget.exactWindow(.init(
            identity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: processIdentifier,
                ownerProcessStartIdentity: generation,
                capturedBounds: bounds),
            bounds: bounds))
        var typed: [Character] = []
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { character, _, delivery in
                typed.append(character)
                return .dispatched(delivery: delivery, keyPressCount: 1)
            })

        let processSummary = try await service.typeActionsTrackingSecureInput(
            [.text("p")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: process)
        let exactSummary = try await service.typeActionsTrackingSecureInput(
            [.text("w")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: exactWindow)

        #expect(typed == ["p", "w"])
        #expect(processSummary.executionResult.outcome.delivery == .init(
            mechanism: .processTargetedEvents,
            mode: .background))
        #expect(exactSummary.executionResult.outcome.delivery == .init(
            mechanism: .windowTargetedEvents,
            mode: .background))
    }

    @Test
    @MainActor
    func `targeted text and special keys report AX event and mixed dispatch shapes`() async throws {
        let processIdentifier = getpid()
        let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        let exactWindow = try UIAutomationTarget.exactWindow(.init(
            identity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: processIdentifier,
                ownerProcessStartIdentity: 91,
                capturedBounds: bounds),
            bounds: bounds))
        let accessibilityDelivery = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityValue,
            mode: .background)

        let accessibilityService = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _, _ in
                .dispatched(delivery: accessibilityDelivery, keyPressCount: 0)
            },
            targetedSpecialKeyTyper: { _, _, _ in
                .dispatched(delivery: accessibilityDelivery, keyPressCount: 0)
            })
        let accessibility = try await accessibilityService.typeActionsTrackingSecureInput(
            [.text("a"), .key(.space)],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: exactWindow)
        #expect(accessibility.result.totalCharacters == 1)
        #expect(accessibility.result.keyPresses == 0)
        #expect(accessibility.result.specialKeyPresses == 0)
        #expect(accessibility.executionResult.outcome.delivery == accessibilityDelivery)
        #expect(accessibility.executionResult.outcome.dispatchState.unitCount ==
            DesktopActionOutcome.DispatchUnitCount(2))

        let eventService = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _, delivery in
                .dispatched(delivery: delivery, keyPressCount: 1)
            },
            targetedSpecialKeyTyper: { _, _, delivery in
                .dispatched(delivery: delivery, keyPressCount: 1)
            })
        let event = try await eventService.typeActionsTrackingSecureInput(
            [.text("a"), .key(.return)],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: exactWindow)
        #expect(event.result.keyPresses == 2)
        #expect(event.result.specialKeyPresses == 1)
        #expect(event.executionResult.outcome.delivery == exactWindow.keyboardDelivery)
        #expect(event.executionResult.outcome.dispatchState.unitCount ==
            DesktopActionOutcome.DispatchUnitCount(2))

        let mixedService = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _, _ in
                .dispatched(delivery: accessibilityDelivery, keyPressCount: 0)
            },
            targetedSpecialKeyTyper: { _, _, delivery in
                .dispatched(delivery: delivery, keyPressCount: 1)
            })
        let mixed = try await mixedService.typeActionsTrackingSecureInput(
            [.text("a"), .key(.return)],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: exactWindow)
        #expect(mixed.result.keyPresses == 1)
        #expect(mixed.result.specialKeyPresses == 1)
        #expect(mixed.executionResult.outcome.delivery == .init(
            mechanism: .composite,
            mode: .background))
        #expect(mixed.executionResult.outcome.dispatchState.unitCount ==
            DesktopActionOutcome.DispatchUnitCount(2))

        let mixedSpecialService = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedSpecialKeyTyper: { key, _, delivery in
                key == .space
                    ? .dispatched(delivery: accessibilityDelivery, keyPressCount: 0)
                    : .dispatched(delivery: delivery, keyPressCount: 1)
            })
        let mixedSpecial = try await mixedSpecialService.typeActionsTrackingSecureInput(
            [.key(.space), .key(.return)],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: exactWindow)
        #expect(mixedSpecial.result.totalCharacters == 0)
        #expect(mixedSpecial.result.keyPresses == 1)
        #expect(mixedSpecial.result.specialKeyPresses == 1)
        #expect(mixedSpecial.executionResult.outcome.delivery == .init(
            mechanism: .composite,
            mode: .background))
        #expect(mixedSpecial.executionResult.outcome.dispatchState.unitCount ==
            DesktopActionOutcome.DispatchUnitCount(2))
    }

    @Test
    @MainActor
    func `targeted keyboard clear and AX text keep special key events distinct`() async throws {
        let processIdentifier = getpid()
        let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        let target = try UIAutomationTarget.exactWindow(.init(
            identity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: processIdentifier,
                ownerProcessStartIdentity: 91,
                capturedBounds: bounds),
            bounds: bounds))
        let accessibilityDelivery = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityValue,
            mode: .background)
        var keyTaps: [(CGKeyCode, CGEventFlags)] = []
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _, _ in
                .dispatched(delivery: accessibilityDelivery, keyPressCount: 0)
            },
            targetedKeyTapper: { keyCode, modifiers, _ in
                keyTaps.append((keyCode, modifiers))
            },
            targetedTextReplacer: { _, _ in false })

        let summary = try await service.typeActionsTrackingSecureInput(
            [.clear, .text("x")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: target)

        #expect(keyTaps.map(\.0) == [0x00, TypeServiceSpecialKeyMapping.keyCode(for: .delete)])
        #expect(summary.result.totalCharacters == 1)
        #expect(summary.result.keyPresses == 2)
        #expect(summary.result.specialKeyPresses == 2)
        #expect(summary.executionResult.outcome.delivery == .init(
            mechanism: .composite,
            mode: .background))
        #expect(summary.executionResult.outcome.dispatchState.unitCount ==
            DesktopActionOutcome.DispatchUnitCount(3))
    }

    @Test
    @MainActor
    func `targeted special key no change reports zero dispatch`() async throws {
        let processIdentifier = getpid()
        let target = try UIAutomationTarget.process(.init(
            processIdentifier: processIdentifier,
            identity: .init(processIdentifier: processIdentifier, processStartIdentity: 91)))
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedSpecialKeyTyper: { _, _, _ in .noChange })

        let summary = try await service.typeActionsTrackingSecureInput(
            [.key(.delete)],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: target)

        #expect(summary.result.keyPresses == 0)
        #expect(summary.result.specialKeyPresses == 0)
        #expect(summary.executionResult.outcome.state == .confirmedNoChange)
        #expect(summary.executionResult.outcome.dispatchState == .none)
        #expect(summary.executionResult.outcome.delivery == nil)
    }

    @Test
    @MainActor
    func `action-first missing snapshot fails as stale instead of falling back`() async {
        let service = TypeService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst))

        do {
            try await service.type(
                text: "hello",
                target: "T1",
                clearExisting: true,
                typingDelay: 0,
                snapshotId: "missing")
            Issue.record("Expected stale element error for missing action snapshot.")
        } catch let error as ActionInputError {
            #expect(error == .staleElement)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @MainActor
    func `synthetic type treats explicit missing snapshot as authoritative`() async {
        let service = TypeService(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly))

        do {
            try await service.type(
                text: "hello",
                target: "missing-\(UUID().uuidString)",
                clearExisting: false,
                typingDelay: 0,
                snapshotId: "missing")
            Issue.record("Expected stale element error for missing synthetic snapshot.")
        } catch let error as ActionInputError {
            #expect(error == .staleElement)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @MainActor
    func `action-first type does not escape an explicit snapshot`() async throws {
        let snapshotId = SnapshotReferenceFixtures.first.rawValue
        let detectionResult = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 0, method: "test"))
        let resolver = RecordingTypeAutomationElementResolver()
        let service = try await TypeService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            automationElementResolver: resolver)

        do {
            try await service.type(
                text: "hello",
                target: "outside-snapshot",
                clearExisting: true,
                typingDelay: 0,
                snapshotId: snapshotId)
            Issue.record("Expected missing snapshot target error.")
        } catch let PeekabooError.elementNotFound(identifier) {
            #expect(identifier == "outside-snapshot")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(resolver.queryResolutionCount == 0)
    }

    @Test
    @MainActor
    func `direct OCR target refuses before AX resolution or typing`() async throws {
        let element = DetectedElement(
            id: "ocr_1",
            type: .staticText,
            label: "August",
            bounds: CGRect(x: 10, y: 20, width: 100, height: 20),
            attributes: [
                "description": "ocr",
                "confidence": "0.93",
            ])
        let result = ElementDetectionResult(
            snapshotId: SnapshotReferenceFixtures.second.rawValue,
            screenshotPath: "/tmp/calendar.png",
            elements: DetectedElements(other: [element]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "AXorcist+OCR"))
        let resolver = RecordingTypeAutomationElementResolver()
        var typed: [Character] = []
        let service = try await TypeService(
            snapshotManager: InMemorySnapshotManager.containing(result),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            automationElementResolver: resolver,
            randomSource: SystemTypingCadenceRandomSource(),
            targetedCharacterTyper: { character, _, delivery in
                typed.append(character)
                return .dispatched(delivery: delivery, keyPressCount: 1)
            })

        do {
            try await service.type(
                text: "unsafe",
                target: "ocr_1",
                clearExisting: false,
                typingDelay: 0,
                snapshotId: SnapshotReferenceFixtures.second.rawValue)
            Issue.record("Expected OCR semantic evidence refusal")
        } catch let PeekabooError.invalidInput(message) {
            #expect(message.contains("semantic evidence"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(resolver.detectedResolutionCount == 0)
        #expect(resolver.queryResolutionCount == 0)
        #expect(typed.isEmpty)
    }

    @Test
    func `special key mapping preserves raw SpecialKey semantics`() {
        #expect(TypeServiceSpecialKeyMapping.keyCode(for: .return) == 0x24)
        #expect(TypeServiceSpecialKeyMapping.keyCode(for: .enter) == 0x4C)
        #expect(TypeServiceSpecialKeyMapping.keyCode(for: .forwardDelete) == 0x75)
        #expect(TypeServiceSpecialKeyMapping.keyCode(for: .capsLock) == 0x39)
        #expect(TypeServiceSpecialKeyMapping.keyCode(for: .clear) == 0x47)
        #expect(TypeServiceSpecialKeyMapping.keyCode(for: .help) == 0x72)
    }

    private static func unicodeString(from event: CGEvent) -> String {
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: 0,
            actualStringLength: &length,
            unicodeString: nil)
        var buffer = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }

    @Test
    func `special key mapping accepts CLI aliases`() {
        #expect(TypeServiceSpecialKeyMapping.keyCode(forRawKey: "esc") == 0x35)
        #expect(TypeServiceSpecialKeyMapping.keyCode(forRawKey: "spacebar") == 0x31)
        #expect(TypeServiceSpecialKeyMapping.keyCode(forRawKey: "forward_delete") == 0x75)
        #expect(TypeServiceSpecialKeyMapping.keyCode(forRawKey: "caps_lock") == 0x39)
        #expect(TypeServiceSpecialKeyMapping.keyCode(forRawKey: "page_up") == 0x74)
        #expect(TypeServiceSpecialKeyMapping.keyCode(forRawKey: "arrow_down") == 0x7D)
    }

    @Test
    @MainActor
    func `resolveTargetElement matches identifier over other fields`() {
        let basic = DetectedElement(
            id: "T1",
            type: .textField,
            label: "Type here...",
            value: nil,
            bounds: .init(x: 0, y: 0, width: 100, height: 20),
            isEnabled: true,
            isSelected: nil,
            attributes: ["identifier": "basic-text-field"])
        let number = DetectedElement(
            id: "T2",
            type: .textField,
            label: "Numbers only...",
            value: nil,
            bounds: .init(x: 0, y: 24, width: 100, height: 20),
            isEnabled: true,
            isSelected: nil,
            attributes: ["identifier": "number-text-field"])

        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(textFields: [basic, number]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 2, method: "test"))

        #expect(TypeService.resolveTargetElement(query: "basic-text-field", in: detectionResult)?.id == "T1")
        #expect(TypeService.resolveTargetElement(query: "number-text-field", in: detectionResult)?.id == "T2")
        #expect(TypeService.resolveTargetElement(query: "Type here...", in: detectionResult)?.id == "T1")
        #expect(TypeService.resolveTargetElement(query: "Numbers only...", in: detectionResult)?.id == "T2")
    }

    @Test
    @MainActor
    func `resolveTargetElement returns nil for unknown query`() {
        let element = DetectedElement(
            id: "T1",
            type: .textField,
            label: "Type here...",
            value: nil,
            bounds: .init(x: 0, y: 0, width: 100, height: 20),
            isEnabled: true,
            isSelected: nil,
            attributes: ["identifier": "basic-text-field"])

        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(textFields: [element]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "test"))

        #expect(TypeService.resolveTargetElement(query: "does-not-exist", in: detectionResult) == nil)
    }

    @Test
    @MainActor
    func `resolveTargetElement breaks ties deterministically`() {
        let higher = DetectedElement(
            id: "T_HIGH",
            type: .textField,
            label: "Type here...",
            value: nil,
            bounds: .init(x: 0, y: 100, width: 100, height: 20),
            isEnabled: true,
            isSelected: nil,
            attributes: ["identifier": "basic-text-field"])
        let lower = DetectedElement(
            id: "T_LOW",
            type: .textField,
            label: "Type here...",
            value: nil,
            bounds: .init(x: 0, y: 40, width: 100, height: 20),
            isEnabled: true,
            isSelected: nil,
            attributes: ["identifier": "basic-text-field"])

        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(textFields: [higher, lower]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 2, method: "test"))

        #expect(TypeService.resolveTargetElement(query: "basic-text-field", in: detectionResult)?.id == "T_LOW")
    }
}

private enum TypeDeliveryTestError: LocalizedError {
    case destinationDrifted

    var errorDescription: String? {
        "destination drifted"
    }
}

@MainActor
private final class RecordingTypeAutomationElementResolver: AutomationElementResolving {
    private(set) var detectedResolutionCount = 0
    private(set) var queryResolutionCount = 0

    func resolve(detectedElement _: DetectedElement, windowContext _: WindowContext?) -> AutomationElement? {
        self.detectedResolutionCount += 1
        return nil
    }

    func resolve(query _: String, windowContext _: WindowContext?, requireTextInput _: Bool) -> AutomationElement? {
        self.queryResolutionCount += 1
        return nil
    }
}
