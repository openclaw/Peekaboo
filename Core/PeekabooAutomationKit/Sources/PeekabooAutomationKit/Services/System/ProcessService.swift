import Foundation
import PeekabooFoundation

/// Implementation of ProcessServiceProtocol for executing Peekaboo scripts
@available(macOS 14.0, *)
@MainActor
public final class ProcessService: ProcessServiceProtocol {
    let applicationService: any ApplicationServiceProtocol
    let screenCaptureService: any ScreenCaptureServiceProtocol
    let snapshotManager: any SnapshotManagerProtocol
    let uiAutomationService: any UIAutomationServiceProtocol
    let windowManagementService: any WindowManagementServiceProtocol
    let menuService: any MenuServiceProtocol
    let dockService: any DockServiceProtocol
    let clipboardService: any ClipboardServiceProtocol
    let screenService: any ScreenServiceProtocol

    public init(
        applicationService: any ApplicationServiceProtocol,
        screenCaptureService: any ScreenCaptureServiceProtocol,
        snapshotManager: any SnapshotManagerProtocol,
        uiAutomationService: any UIAutomationServiceProtocol,
        windowManagementService: any WindowManagementServiceProtocol,
        menuService: any MenuServiceProtocol,
        dockService: any DockServiceProtocol,
        clipboardService: any ClipboardServiceProtocol,
        screenService: any ScreenServiceProtocol)
    {
        self.applicationService = applicationService
        self.screenCaptureService = screenCaptureService
        self.snapshotManager = snapshotManager
        self.uiAutomationService = uiAutomationService
        self.windowManagementService = windowManagementService
        self.menuService = menuService
        self.dockService = dockService
        self.clipboardService = clipboardService
        self.screenService = screenService
    }

    public convenience init(
        applicationService: any ApplicationServiceProtocol,
        screenCaptureService: any ScreenCaptureServiceProtocol,
        snapshotManager: any SnapshotManagerProtocol,
        uiAutomationService: any UIAutomationServiceProtocol,
        windowManagementService: any WindowManagementServiceProtocol,
        menuService: any MenuServiceProtocol,
        dockService: any DockServiceProtocol,
        clipboardService: any ClipboardServiceProtocol)
    {
        self.init(
            applicationService: applicationService,
            screenCaptureService: screenCaptureService,
            snapshotManager: snapshotManager,
            uiAutomationService: uiAutomationService,
            windowManagementService: windowManagementService,
            menuService: menuService,
            dockService: dockService,
            clipboardService: clipboardService,
            screenService: ScreenService())
    }

    public convenience init(
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient())
    {
        let snapshotManager = SnapshotManager()
        let loggingService = LoggingService()
        let applicationService = ApplicationService(feedbackClient: feedbackClient)
        let windowManagementService = WindowManagementService(
            applicationService: applicationService,
            feedbackClient: feedbackClient)
        let menuService = MenuService(feedbackClient: feedbackClient)
        let dockService = DockService(feedbackClient: feedbackClient)
        let clipboardService = ClipboardService()
        let uiAutomationService = UIAutomationService(
            snapshotManager: snapshotManager,
            loggingService: loggingService,
            feedbackClient: feedbackClient)

        let baseCaptureDeps = ScreenCaptureService.Dependencies.live()
        let captureDeps = ScreenCaptureService.Dependencies(
            feedbackClient: feedbackClient,
            permissionEvaluator: baseCaptureDeps.permissionEvaluator,
            fallbackRunner: baseCaptureDeps.fallbackRunner,
            applicationResolver: baseCaptureDeps.applicationResolver,
            makeFrameSource: baseCaptureDeps.makeFrameSource,
            makeModernOperator: baseCaptureDeps.makeModernOperator,
            makeLegacyOperator: baseCaptureDeps.makeLegacyOperator)
        let screenCaptureService = ScreenCaptureService(
            loggingService: loggingService,
            dependencies: captureDeps)

        self.init(
            applicationService: applicationService,
            screenCaptureService: screenCaptureService,
            snapshotManager: snapshotManager,
            uiAutomationService: uiAutomationService,
            windowManagementService: windowManagementService,
            menuService: menuService,
            dockService: dockService,
            clipboardService: clipboardService,
            screenService: ScreenService())
    }

    public func loadScript(from path: String) async throws -> PeekabooScript {
        let resolvedPath = PathResolver.expandPath(path)
        let url = URL(fileURLWithPath: resolvedPath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PeekabooError.fileIOError("Script file not found: \(resolvedPath)")
        }

        return try await performOperation({
            let data = try Data(contentsOf: url)
            let decoder = JSONCoding.makeDecoder()
            do {
                return try decoder.decode(PeekabooScript.self, from: data)
            } catch let decodingError as DecodingError {
                throw PeekabooError.invalidInput(Self.describeScriptDecodingError(decodingError, path: resolvedPath))
            }
        }, errorContext: "Failed to load script from \(resolvedPath)")
    }

    private nonisolated static func describeScriptDecodingError(_ error: DecodingError, path: String) -> String {
        let hint = "Tip: use a flat params object " +
            "(e.g. `{\"params\":{\"app\":\"TextEdit\",\"text\":\"hello\"}}`)."

        func formatContext(_ context: DecodingError.Context) -> String {
            let codingPath = context.codingPath.map(\.stringValue).joined(separator: ".")
            if codingPath.isEmpty {
                return context.debugDescription
            }
            return "\(context.debugDescription) (at \(codingPath))"
        }

        let details: String
        switch error {
        case let .typeMismatch(_, context):
            details = formatContext(context)
        case let .valueNotFound(_, context):
            details = formatContext(context)
        case let .keyNotFound(key, context):
            let base = formatContext(context)
            let codingPath = (context.codingPath + [key]).map(\.stringValue).joined(separator: ".")
            details = "\(base) (missing key \(codingPath))"
        case let .dataCorrupted(context):
            details = formatContext(context)
        @unknown default:
            details = String(describing: error)
        }

        return [
            "Invalid script JSON in \(path).",
            details,
            hint,
        ].joined(separator: " ")
    }

    public func executeScript(
        _ script: PeekabooScript,
        failFast: Bool,
        verbose: Bool) async throws -> [StepResult]
    {
        var results: [StepResult] = []
        var currentSnapshotId: String?

        for (index, step) in script.steps.indexed() {
            let stepNumber = index + 1
            let stepStartTime = Date()

            do {
                // Execute the step
                let executionResult = try await executeStep(step, snapshotId: currentSnapshotId)

                // Update snapshot ID if a new one was created
                if let newSnapshotId = executionResult.snapshotId {
                    currentSnapshotId = newSnapshotId
                }

                let result = StepResult(
                    stepId: step.stepId,
                    stepNumber: stepNumber,
                    command: step.command,
                    success: true,
                    output: executionResult.output,
                    error: nil,
                    executionTime: Date().timeIntervalSince(stepStartTime),
                    startedAt: stepStartTime,
                    snapshotId: executionResult.snapshotId,
                    desktopMutationCompletedAt: executionResult.desktopMutationCompletedAt,
                    desktopMutationPreservationAllowed: executionResult.desktopMutationPreservationAllowed)

                results.append(result)

            } catch {
                let result = StepResult(
                    stepId: step.stepId,
                    stepNumber: stepNumber,
                    command: step.command,
                    success: false,
                    output: nil,
                    error: error.localizedDescription,
                    executionTime: Date().timeIntervalSince(stepStartTime),
                    startedAt: stepStartTime)

                results.append(result)

                if failFast {
                    break
                }
            }
        }

        return results
    }
}

@MainActor
extension ProcessService {
    public func executeStep(
        _ step: ScriptStep,
        snapshotId: String?) async throws -> StepExecutionResult
    {
        let normalizedStep = self.normalizeStepParameters(step)

        switch normalizedStep.command.lowercased() {
        case "see":
            return try await self.executeSeeCommand(normalizedStep, snapshotId: snapshotId)
        case "click":
            return try await self.executeClickCommand(normalizedStep, snapshotId: snapshotId)
        case "type":
            return try await self.executeTypeCommand(normalizedStep, snapshotId: snapshotId)
        case "scroll":
            return try await self.executeScrollCommand(normalizedStep, snapshotId: snapshotId)
        case "swipe":
            return try await self.executeSwipeCommand(normalizedStep, snapshotId: snapshotId)
        case "drag":
            return try await self.executeDragCommand(normalizedStep, snapshotId: snapshotId)
        case "hotkey":
            return try await self.executeHotkeyCommand(normalizedStep, snapshotId: snapshotId)
        case "sleep":
            return try await self.executeSleepCommand(normalizedStep)
        case "window":
            return try await self.executeWindowCommand(normalizedStep, snapshotId: snapshotId)
        case "menu":
            return try await self.executeMenuCommand(normalizedStep, snapshotId: snapshotId)
        case "dock":
            return try await self.executeDockCommand(normalizedStep)
        case "app":
            return try await self.executeAppCommand(normalizedStep)
        case "clipboard":
            return try await self.executeClipboardCommand(normalizedStep)
        default:
            throw PeekabooError.invalidInput(field: "command", reason: "Unknown command: \(step.command)")
        }
    }
}
