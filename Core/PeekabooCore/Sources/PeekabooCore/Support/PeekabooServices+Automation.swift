import Algorithms
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooFoundation

/// High-level convenience methods.
extension PeekabooServices {
    /// Perform UI automation with automatic snapshot management.
    /// - Parameters:
    ///   - appIdentifier: Target application
    ///   - actions: Automation actions to perform
    /// - Returns: Automation result
    public func automate(
        appIdentifier: String,
        actions: [AutomationAction]) async throws -> AutomationResult
    {
        self.logger.info("\(AgentDisplayTokens.Status.running) Starting automation for app: \(appIdentifier)")
        self.logger.debug("Number of actions: \(actions.count)")

        for action in actions {
            if case let .wait(milliseconds) = action, milliseconds < 0 {
                throw PeekabooError.invalidInput("Automation wait duration cannot be negative")
            }
        }

        let preparation = try await self.prepareAutomationSnapshot(appIdentifier: appIdentifier)
        let executedActions = try await self.executeAutomationActions(actions, snapshotId: preparation.snapshotId)

        let successCount = executedActions.count(where: { $0.success })
        let summary = "\(AgentDisplayTokens.Status.success) Automation complete: "
            + "\(successCount)/\(executedActions.count) actions succeeded"
        self.logger.info("\(summary)")

        return AutomationResult(
            snapshotId: preparation.snapshotId,
            actions: executedActions,
            initialScreenshot: preparation.initialScreenshot)
    }

    private func prepareAutomationSnapshot(appIdentifier: String) async throws -> AutomationPreparation {
        let snapshotId = try await self.snapshots.createSnapshot()
        self.logger.debug("Created snapshot: \(snapshotId)")

        self.logger.debug("Capturing initial window state")
        let captureResult = try await self.screenCapture.captureWindow(appIdentifier: appIdentifier, windowIndex: nil)

        self.logger.debug("Detecting UI elements")
        let windowContext = WindowContext(
            applicationName: captureResult.metadata.applicationInfo?.name,
            windowTitle: captureResult.metadata.windowInfo?.title,
            windowBounds: captureResult.metadata.windowInfo?.bounds)

        let detectionResult = try await self.automation.detectElements(
            in: captureResult.imageData,
            snapshotId: snapshotId,
            windowContext: windowContext)
        self.logger.info("Detected \(detectionResult.elements.all.count) elements")
        try await self.snapshots.storeDetectionResult(snapshotId: snapshotId, result: detectionResult)

        return AutomationPreparation(snapshotId: snapshotId, initialScreenshot: captureResult.savedPath)
    }

    private func executeAutomationActions(
        _ actions: [AutomationAction],
        snapshotId: String) async throws -> [ExecutedAction]
    {
        var executedActions: [ExecutedAction] = []

        for (index, action) in actions.indexed() {
            self.logger
                .info("Executing action \(index + 1)/\(actions.count): \(String(describing: action), privacy: .public)")
            let startTime = Date()
            do {
                try await self.performAutomationAction(action, snapshotId: snapshotId)
                let duration = Date().timeIntervalSince(startTime)
                let successMessage =
                    "\(AgentDisplayTokens.Status.success) Action completed in " +
                    "\(self.formatDuration(duration))s"
                self.logger.debug("\(successMessage, privacy: .public)")

                executedActions.append(ExecutedAction(
                    action: action,
                    success: true,
                    duration: duration,
                    error: nil))
            } catch {
                let duration = Date().timeIntervalSince(startTime)
                let peekabooError = error.asPeekabooError(context: "Action execution failed")
                let failureMessage =
                    "\(AgentDisplayTokens.Status.failure) Action failed after " +
                    "\(self.formatDuration(duration))s: \(peekabooError.localizedDescription)"
                self.logger.error("\(failureMessage, privacy: .public)")

                executedActions.append(ExecutedAction(
                    action: action,
                    success: false,
                    duration: duration,
                    error: peekabooError.localizedDescription))
                throw peekabooError
            }
        }

        return executedActions
    }

    private func performAutomationAction(_ action: AutomationAction, snapshotId: String) async throws {
        switch action {
        case let .click(target, clickType):
            try await self.automation.click(target: target, clickType: clickType, snapshotId: snapshotId)
        case let .type(text, target, clear):
            try await self.automation.type(
                text: text,
                target: target,
                clearExisting: clear,
                typingDelay: 50,
                snapshotId: snapshotId)
        case let .scroll(direction, amount, target):
            let request = ScrollRequest(
                direction: direction,
                amount: amount,
                target: target,
                smooth: false,
                delay: 10,
                snapshotId: snapshotId)
            try await self.automation.scroll(request)
        case let .hotkey(keys):
            try await self.automation.hotkey(keys: keys, holdDuration: 100)
        case let .wait(milliseconds):
            try await Task.sleep(for: .milliseconds(milliseconds))
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        String(format: "%.2f", interval)
    }
}

private struct AutomationPreparation {
    let snapshotId: String
    let initialScreenshot: String?
}
