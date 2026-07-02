import AppKit
import Foundation
import os.log
import PeekabooFoundation

/// Dialog-specific errors
public enum DialogError: Error {
    case noActiveDialog
    case dialogNotFound
    case noFileDialog
    case buttonNotFound(String)
    case fieldNotFound
    case invalidFieldIndex
    case noTextFields
    case noDismissButton
    case fileVerificationFailed(expectedPath: String)
    case fileSavedToUnexpectedDirectory(expectedDirectory: String, actualDirectory: String, actualPath: String)
    case inputSuppressedUnderTests
}

extension DialogError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noActiveDialog:
            "No active dialog window found."
        case .dialogNotFound:
            "Dialog not found."
        case .noFileDialog:
            "No file dialog (Save/Open) found."
        case let .buttonNotFound(name):
            "Button not found: \(name)"
        case .fieldNotFound:
            "Field not found."
        case .invalidFieldIndex:
            "Invalid field index."
        case .noTextFields:
            "No text fields found in dialog."
        case .noDismissButton:
            "No dismiss button found in dialog."
        case let .fileVerificationFailed(expectedPath):
            "Dialog reported success, but the saved file did not appear at: \(expectedPath)"
        case let .fileSavedToUnexpectedDirectory(expectedDirectory, actualDirectory, actualPath):
            "Saved file landed in '\(actualDirectory)', expected '\(expectedDirectory)' (actual: \(actualPath))"
        case .inputSuppressedUnderTests:
            "Dialog keyboard input is suppressed under tests; inject a typeCharacterHandler to record input."
        }
    }
}

/// Default implementation of dialog management operations
@MainActor
public final class DialogService: DialogServiceProtocol {
    let logger = Logger(subsystem: "boo.peekaboo.core", category: "DialogService")
    let dialogTitleHints = ["open", "save", "export", "import", "choose", "replace"]
    let activeDialogSearchTimeout: Float = 0.25
    let targetedDialogSearchTimeout: Float = 0.5
    let applicationService: any ApplicationServiceProtocol
    let syntheticInputDriver: any SyntheticInputDriving
    let focusService = FocusManagementService()
    let windowIdentityService = WindowIdentityService()
    let feedbackClient: any AutomationFeedbackClient
    var scansAllApplicationsForDialogs: Bool {
        ProcessInfo.processInfo.environment["PEEKABOO_DIALOG_SCAN_ALL_APPS"] == "1"
    }

    public convenience init(
        applicationService: (any ApplicationServiceProtocol)? = nil,
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient())
    {
        self.init(
            applicationService: applicationService,
            feedbackClient: feedbackClient,
            syntheticInputDriver: SyntheticInputDriver())
    }

    init(
        applicationService: (any ApplicationServiceProtocol)? = nil,
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient(),
        syntheticInputDriver: any SyntheticInputDriving)
    {
        self.applicationService = applicationService ?? ApplicationService()
        self.feedbackClient = feedbackClient
        self.syntheticInputDriver = syntheticInputDriver
        self.logger.debug("DialogService initialized")
        // Connect to visual feedback if available.
        let isMacApp = Bundle.main.bundleIdentifier?.hasPrefix("boo.peekaboo.mac") == true
        if !isMacApp {
            self.logger.debug("Connecting to visualizer service (running as CLI/external tool)")
            self.feedbackClient.connect()
        } else {
            self.logger.debug("Skipping visualizer connection (running inside Mac app)")
        }
    }
}
