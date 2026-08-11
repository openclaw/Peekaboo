import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct UIInputDispatcherTests {
    @Test
    func `action-first success returns action path`() async throws {
        var synthCalled = false

        let result = try await UIInputDispatcher.run(
            verb: .click,
            strategy: .actionFirst,
            action: {
                UIInputExecutionReceipt.Action(
                    outcome: Self.actionOutcome,
                    actionName: "AXPress",
                    anchorPoint: nil,
                    elementRole: "AXButton")
            },
            synth: {
                synthCalled = true
                return Self.synthOutcome
            })

        #expect(result.path == .action)
        #expect(result.outcome == Self.actionOutcome)
        #expect(result.actionName == "AXPress")
        #expect(result.elementRole == "AXButton")
        #expect(!synthCalled)
    }

    @Test
    func `action-first unsupported action falls back to synth`() async throws {
        var synthCalled = false

        let result = try await UIInputDispatcher.run(
            verb: .click,
            strategy: .actionFirst,
            action: {
                throw ActionInputError.unsupported(.actionUnsupported)
            },
            synth: {
                synthCalled = true
                return Self.synthOutcome
            })

        #expect(result.path == .synth)
        #expect(result.outcome == Self.synthOutcome)
        #expect(result.fallbackReason == .actionUnsupported)
        #expect(synthCalled)
    }

    @Test
    func `action-first fallback eligible action gaps all fall back to synth`() async throws {
        let fallbackReasons: [ActionInputUnsupportedReason] = [
            .actionUnsupported,
            .attributeUnsupported,
            .valueNotSettable,
            .secureValueNotAllowed,
            .menuShortcutUnavailable,
            .missingElement,
        ]

        for reason in fallbackReasons {
            var synthCalled = false

            let result = try await UIInputDispatcher.run(
                verb: .click,
                strategy: .actionFirst,
                action: {
                    throw ActionInputError.unsupported(reason)
                },
                synth: {
                    synthCalled = true
                    return Self.synthOutcome
                })

            #expect(result.path == .synth)
            #expect(result.fallbackReason?.rawValue == reason.fallbackReason.rawValue)
            #expect(synthCalled)
        }
    }

    @Test
    func `action-first stale element does not fall back to synth`() async {
        var synthCalled = false

        do {
            _ = try await UIInputDispatcher.run(
                verb: .click,
                strategy: .actionFirst,
                action: {
                    throw ActionInputError.staleElement
                },
                synth: {
                    synthCalled = true
                    return Self.synthOutcome
                })
            Issue.record("Expected stale action element to throw.")
        } catch let error as ActionInputError {
            #expect(error == .staleElement)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!synthCalled)
    }

    @Test
    func `action-first permission denied does not fall back to synth`() async {
        var synthCalled = false

        do {
            _ = try await UIInputDispatcher.run(
                verb: .click,
                strategy: .actionFirst,
                action: {
                    throw ActionInputError.permissionDenied
                },
                synth: {
                    synthCalled = true
                    return Self.synthOutcome
                })
            Issue.record("Expected permission denial to throw.")
        } catch let error as ActionInputError {
            #expect(error == .permissionDenied)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!synthCalled)
    }

    @Test
    func `action-first target unavailable does not fall back to synth`() async {
        var synthCalled = false

        do {
            _ = try await UIInputDispatcher.run(
                verb: .click,
                strategy: .actionFirst,
                action: {
                    throw ActionInputError.targetUnavailable
                },
                synth: {
                    synthCalled = true
                    return Self.synthOutcome
                })
            Issue.record("Expected target unavailable to throw.")
        } catch let error as ActionInputError {
            #expect(error == .targetUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!synthCalled)
    }

    @Test
    func `action-only unsupported action throws without synthesis fallback`() async {
        var synthCalled = false

        do {
            _ = try await UIInputDispatcher.run(
                verb: .performAction,
                strategy: .actionOnly,
                action: {
                    throw ActionInputError.unsupported(.actionUnsupported)
                },
                synth: {
                    synthCalled = true
                    return Self.synthOutcome
                })
            Issue.record("Expected action-only unsupported action to throw.")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!synthCalled)
    }

    @Test
    func `synth-first preserves current behavior and does not call action`() async throws {
        var actionCalled = false
        var synthCalled = false

        let result = try await UIInputDispatcher.run(
            verb: .click,
            strategy: .synthFirst,
            action: {
                actionCalled = true
                return UIInputExecutionReceipt.Action(
                    outcome: Self.actionOutcome,
                    actionName: "AXPress",
                    anchorPoint: nil,
                    elementRole: nil)
            },
            synth: {
                synthCalled = true
                return Self.synthOutcome
            })

        #expect(result.path == .synth)
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.effect == .unverifiable)
        #expect(!actionCalled)
        #expect(synthCalled)
    }

    @Test
    func `synth-only never calls action driver`() async throws {
        var actionCalled = false
        var synthCalled = false

        let result = try await UIInputDispatcher.run(
            verb: .scroll,
            strategy: .synthOnly,
            action: {
                actionCalled = true
                return UIInputExecutionReceipt.Action(
                    outcome: Self.actionOutcome,
                    actionName: "AXScrollDownByPage",
                    anchorPoint: nil,
                    elementRole: nil)
            },
            synth: {
                synthCalled = true
                return Self.synthOutcome
            })

        #expect(result.path == .synth)
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.effect == .unverifiable)
        #expect(!actionCalled)
        #expect(synthCalled)
    }

    @Test
    func `action-only missing action throws without synthesis fallback`() async {
        var synthCalled = false

        do {
            _ = try await UIInputDispatcher.run(
                verb: .click,
                strategy: .actionOnly,
                action: nil,
                synth: {
                    synthCalled = true
                    return Self.synthOutcome
                })
            Issue.record("Expected action-only without an action closure to throw.")
        } catch {}

        #expect(!synthCalled)
    }

    private static let actionOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .accessibilityAction, mode: .background),
        evidence: .deliveryAccepted)

    private static let synthOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .processTargetedEvents, mode: .background),
        evidence: .deliveryAccepted)
}

extension ActionInputUnsupportedReason {
    fileprivate var fallbackReason: UIInputFallbackReason {
        switch self {
        case .actionUnsupported:
            .actionUnsupported
        case .attributeUnsupported:
            .attributeUnsupported
        case .valueNotSettable:
            .valueNotSettable
        case .secureValueNotAllowed:
            .secureValueNotAllowed
        case .menuShortcutUnavailable:
            .menuShortcutUnavailable
        case .missingElement:
            .missingElement
        }
    }
}
