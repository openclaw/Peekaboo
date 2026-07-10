@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct SyntheticInputDriverTests {
    @Test
    func `click service uses injected synthetic driver`() async throws {
        let synthetic = RecordingSyntheticInputDriver()
        let service = ClickService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        let result = try await service.click(
            target: .coordinates(CGPoint(x: 12, y: 34)),
            clickType: .double,
            snapshotId: nil)

        #expect(result.path == UIInputExecutionPath.synth)
        #expect(synthetic.events == [
            .click(point: CGPoint(x: 12, y: 34), button: .left, count: 2),
        ])
    }

    @Test
    func `scroll service uses injected synthetic driver`() async throws {
        let synthetic = RecordingSyntheticInputDriver(currentLocation: CGPoint(x: 20, y: 40))
        let service = ScrollService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        let result = try await service.scroll(ScrollRequest(
            direction: .down,
            amount: 2,
            target: nil,
            smooth: false,
            delay: 0,
            snapshotId: nil))

        #expect(result.path == UIInputExecutionPath.synth)
        #expect(synthetic.events == [
            .currentLocation,
            .scroll(deltaX: 0, deltaY: -50, at: CGPoint(x: 20, y: 40)),
            .scroll(deltaX: 0, deltaY: -50, at: CGPoint(x: 20, y: 40)),
        ])
    }

    @Test
    func `action-first scroll preserves wheel tick amount through synthetic fallback`() async throws {
        let synthetic = RecordingSyntheticInputDriver(currentLocation: CGPoint(x: 20, y: 40))
        let service = ScrollService(
            inputPolicy: UIInputPolicy(defaultStrategy: .actionFirst),
            syntheticInputDriver: synthetic)

        let result = try await service.scroll(ScrollRequest(
            direction: .down,
            amount: 3,
            target: nil,
            smooth: false,
            delay: 0,
            snapshotId: nil))

        #expect(result.path == UIInputExecutionPath.synth)
        #expect(result.fallbackReason == .actionUnsupported)
        #expect(synthetic.events == [
            .currentLocation,
            .scroll(deltaX: 0, deltaY: -50, at: CGPoint(x: 20, y: 40)),
            .scroll(deltaX: 0, deltaY: -50, at: CGPoint(x: 20, y: 40)),
            .scroll(deltaX: 0, deltaY: -50, at: CGPoint(x: 20, y: 40)),
        ])
    }

    @Test
    func `type service uses injected synthetic driver`() async throws {
        let synthetic = RecordingSyntheticInputDriver()
        let service = TypeService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic)

        let result = try await service.type(
            text: "ab",
            target: nil,
            clearExisting: true,
            typingDelay: 0,
            snapshotId: nil)

        #expect(result.path == UIInputExecutionPath.synth)
        #expect(synthetic.events == [
            .hotkey(keys: ["cmd", "a"], holdDuration: 0.1),
            .tapKey(.delete, modifiers: []),
            .type("a", delayPerCharacter: 0),
            .type("b", delayPerCharacter: 0),
        ])
    }

    @Test
    func `type action security tracks only nonempty text delivered to a secure field`() {
        #expect(TypeService.actionTypesSensitiveText(.text("secret"), focusedElementIsSecure: true))
        #expect(!TypeService.actionTypesSensitiveText(.text(""), focusedElementIsSecure: true))
        #expect(!TypeService.actionTypesSensitiveText(.key(.tab), focusedElementIsSecure: true))
        #expect(!TypeService.actionTypesSensitiveText(.text("public"), focusedElementIsSecure: false))
    }

    @Test
    func `type actions sample security immediately before every text segment`() async throws {
        let synthetic = RecordingSyntheticInputDriver()
        var securitySamples = [false, true].makeIterator()
        let service = TypeService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in securitySamples.next() ?? false })

        let summary = try await service.typeActionsTrackingSecureInput(
            [.text("public"), .text("secret")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            targetProcessIdentifier: nil)

        #expect(summary.typedIntoSecureField)
        #expect(summary.result.totalCharacters == 12)
        #expect(synthetic.events.compactMap { event -> String? in
            guard case let .type(text, _) = event else { return nil }
            return text
        }.joined() == "publicsecret")
    }
}

@MainActor
private final class RecordingSyntheticInputDriver: SyntheticInputDriving {
    enum Event: Equatable {
        case click(point: CGPoint, button: MouseButton, count: Int)
        case move(CGPoint)
        case currentLocation
        case pressHold(point: CGPoint, button: MouseButton, duration: TimeInterval)
        case scroll(deltaX: Double, deltaY: Double, at: CGPoint?)
        case type(String, delayPerCharacter: TimeInterval)
        case tapKey(SpecialKey, modifiers: CGEventFlags)
        case hotkey(keys: [String], holdDuration: TimeInterval)
    }

    private let location: CGPoint?
    private(set) var events: [Event] = []

    init(currentLocation: CGPoint? = nil) {
        self.location = currentLocation
    }

    func click(at point: CGPoint, button: MouseButton, count: Int) throws {
        self.events.append(.click(point: point, button: button, count: count))
    }

    func click(at point: CGPoint, button: MouseButton, count: Int, targetProcessIdentifier _: pid_t) async throws {
        self.events.append(.click(point: point, button: button, count: count))
    }

    func move(to point: CGPoint) throws {
        self.events.append(.move(point))
    }

    func currentLocation() -> CGPoint? {
        self.events.append(.currentLocation)
        return self.location
    }

    func pressHold(at point: CGPoint, button: MouseButton, duration: TimeInterval) throws {
        self.events.append(.pressHold(point: point, button: button, duration: duration))
    }

    func scroll(deltaX: Double, deltaY: Double, at point: CGPoint?) throws {
        self.events.append(.scroll(deltaX: deltaX, deltaY: deltaY, at: point))
    }

    func type(_ text: String, delayPerCharacter: TimeInterval) throws {
        self.events.append(.type(text, delayPerCharacter: delayPerCharacter))
    }

    func tapKey(_ key: SpecialKey, modifiers: CGEventFlags) throws {
        self.events.append(.tapKey(key, modifiers: modifiers))
    }

    func hotkey(keys: [String], holdDuration: TimeInterval) throws {
        self.events.append(.hotkey(keys: keys, holdDuration: holdDuration))
    }
}
