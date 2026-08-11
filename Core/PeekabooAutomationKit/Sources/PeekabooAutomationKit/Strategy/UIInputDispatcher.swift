import Foundation
import os.log
import PeekabooFoundation

/// Runs one UI input verb according to the selected action/synthesis strategy.
@MainActor
enum UIInputDispatcher {
    private static let logger = Logger(subsystem: "boo.peekaboo.core", category: "UIInputDispatcher")

    static func run(
        verb: UIInputVerb,
        strategy: UIInputStrategy,
        bundleIdentifier: String? = nil,
        action: (() async throws -> UIInputExecutionReceipt.Action)?,
        synth: () async throws -> DesktopActionOutcome) async throws -> UIInputExecutionReceipt
    {
        let startedAt = Date()
        let context = DispatchContext(
            verb: verb,
            strategy: strategy,
            bundleIdentifier: bundleIdentifier,
            startedAt: startedAt)

        switch strategy {
        case .actionFirst:
            do {
                let result = try await self.runAction(action)
                let duration = Date().timeIntervalSince(startedAt)
                self.logPath(
                    context: context,
                    path: .action,
                    fallbackReason: nil,
                    duration: duration)
                return UIInputExecutionReceipt(
                    outcome: result.outcome,
                    verb: verb,
                    strategy: strategy,
                    path: .action,
                    fallbackReason: nil,
                    bundleIdentifier: bundleIdentifier,
                    elementRole: result.elementRole,
                    actionName: result.actionName,
                    anchorPoint: result.anchorPoint,
                    duration: duration)
            } catch let error as ActionInputError where error.allowsSynthesisFallback {
                let reason = error.fallbackReason
                self.logger.debug(
                    """
                    UI input fallback verb=\(verb.rawValue, privacy: .public) \
                    strategy=\(strategy.rawValue, privacy: .public) \
                    reason=\(reason.rawValue, privacy: .public) \
                    bundle=\(bundleIdentifier ?? "<none>", privacy: .public)
                    """)

                return try await self.runSynth(
                    context: context,
                    fallbackReason: reason,
                    synth: synth)
            } catch {
                self.recordFailure(
                    path: .action,
                    context: context)
                throw error
            }

        case .synthFirst:
            return try await self.runSynth(
                context: context,
                fallbackReason: nil,
                synth: synth)

        case .actionOnly:
            do {
                let result = try await self.runAction(action)
                let duration = Date().timeIntervalSince(startedAt)
                self.logPath(
                    context: context,
                    path: .action,
                    fallbackReason: nil,
                    duration: duration)
                return UIInputExecutionReceipt(
                    outcome: result.outcome,
                    verb: verb,
                    strategy: strategy,
                    path: .action,
                    fallbackReason: nil,
                    bundleIdentifier: bundleIdentifier,
                    elementRole: result.elementRole,
                    actionName: result.actionName,
                    anchorPoint: result.anchorPoint,
                    duration: duration)
            } catch {
                self.recordFailure(
                    path: .action,
                    context: context)
                throw error
            }

        case .synthOnly:
            return try await self.runSynth(
                context: context,
                fallbackReason: nil,
                synth: synth)
        }
    }

    private static func runAction(
        _ action: (() async throws -> UIInputExecutionReceipt.Action)?) async throws
        -> UIInputExecutionReceipt.Action
    {
        guard let action else {
            throw ActionInputError.unsupported(.missingElement)
        }
        return try await action()
    }

    private static func runSynth(
        context: DispatchContext,
        fallbackReason: UIInputFallbackReason?,
        synth: () async throws -> DesktopActionOutcome) async throws -> UIInputExecutionReceipt
    {
        do {
            let outcome = try await synth()
            let duration = Date().timeIntervalSince(context.startedAt)
            self.logPath(
                context: context,
                path: .synth,
                fallbackReason: fallbackReason,
                duration: duration)
            return UIInputExecutionReceipt(
                outcome: outcome,
                verb: context.verb,
                strategy: context.strategy,
                path: .synth,
                fallbackReason: fallbackReason,
                bundleIdentifier: context.bundleIdentifier,
                elementRole: nil,
                actionName: nil,
                anchorPoint: nil,
                duration: duration)
        } catch {
            self.recordFailure(
                path: .synth,
                fallbackReason: fallbackReason,
                context: context)
            throw error
        }
    }

    private static func recordFailure(
        path: UIInputExecutionPath,
        fallbackReason: UIInputFallbackReason? = nil,
        context: DispatchContext)
    {
        self.logger.debug(
            """
            UI input failed verb=\(context.verb.rawValue, privacy: .public) \
            strategy=\(context.strategy.rawValue, privacy: .public) \
            path=\(path.rawValue, privacy: .public) \
            fallback=\(fallbackReason?.rawValue ?? "<none>", privacy: .public) \
            bundle=\(context.bundleIdentifier ?? "<none>", privacy: .public)
            """)
    }

    private static func logPath(
        context: DispatchContext,
        path: UIInputExecutionPath,
        fallbackReason: UIInputFallbackReason?,
        duration: TimeInterval)
    {
        self.logger.debug(
            """
            UI input path verb=\(context.verb.rawValue, privacy: .public) \
            strategy=\(context.strategy.rawValue, privacy: .public) \
            path=\(path.rawValue, privacy: .public) \
            fallback=\(fallbackReason?.rawValue ?? "<none>", privacy: .public) \
            bundle=\(context.bundleIdentifier ?? "<none>", privacy: .public) \
            duration=\(duration, privacy: .public)
            """)
    }
}

private struct DispatchContext {
    let verb: UIInputVerb
    let strategy: UIInputStrategy
    let bundleIdentifier: String?
    let startedAt: Date
}

extension ActionInputError {
    var allowsSynthesisFallback: Bool {
        switch self {
        case .unsupported:
            true
        case .staleElement, .permissionDenied, .targetUnavailable, .failed:
            false
        }
    }

    var fallbackReason: UIInputFallbackReason {
        switch self {
        case let .unsupported(reason):
            switch reason {
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
        case .staleElement:
            .staleElement
        case .targetUnavailable, .failed, .permissionDenied:
            .actionFailed
        }
    }
}
