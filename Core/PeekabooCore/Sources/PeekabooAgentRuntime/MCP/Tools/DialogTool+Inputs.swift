import Foundation
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

enum DialogToolAction: String, CaseIterable, Equatable {
    case list
    case click
    case input
    case file
    case dismiss

    init(arguments: ToolArguments) throws {
        guard let raw = arguments.getString("action") else {
            throw DialogToolInputError.missing("action")
        }
        guard let value = DialogToolAction(rawValue: raw) else {
            throw DialogToolInputError.invalid("action", raw)
        }
        self = value
    }
}

enum DialogToolInputError: LocalizedError {
    case missing(String)
    case invalid(String, String)
    case missingForAction(action: DialogToolAction, field: String)
    case foregroundRequired(DialogToolAction)

    var errorDescription: String? {
        switch self {
        case let .missing(field):
            "Missing required parameter: \(field)"
        case let .invalid(field, value):
            "Invalid \(field): \(value)"
        case let .missingForAction(action, field):
            "Missing required parameter for \(action.rawValue): \(field)"
        case let .foregroundRequired(action):
            switch action {
            case .input:
                "Targetless dialog input uses global keyboard input and requires foreground=true."
            case .file:
                "Dialog file uses global keyboard/coordinate input and requires foreground=true."
            case .dismiss:
                "Forced dialog dismiss sends global Escape and requires foreground=true."
            case .click, .list:
                "Dialog \(action.rawValue) requires foreground=true."
            }
        }
    }

    var refusalReason: DesktopActionOutcome.RefusalReason {
        switch self {
        case .foregroundRequired:
            .foregroundConsentRequired
        case .missing, .invalid, .missingForAction:
            .invalidRequest
        }
    }
}

struct DialogToolInputs {
    let app: String?
    let pid: Int?
    let windowId: Int?
    let windowTitle: String?
    let windowIndex: Int?
    let foreground: Bool

    let button: String?
    let text: String?
    let field: String?
    let fieldIndex: Int?
    let clear: Bool

    let path: String?
    let name: String?
    let select: String?
    let ensureExpanded: Bool

    let force: Bool?

    init(arguments: ToolArguments) throws {
        self.app = arguments.getString("app")
        self.pid = try arguments.validatedInt("pid")
        self.windowId = try arguments.validatedInt("window_id")
        self.windowTitle = arguments.getString("window_title")
        self.windowIndex = try arguments.validatedInt("window_index")
        self.foreground = arguments.getBool("foreground") ?? false

        self.button = arguments.getString("button")
        self.text = arguments.getString("text")
        self.field = arguments.getString("field")
        self.fieldIndex = try arguments.validatedInt("field_index")
        self.clear = arguments.getBool("clear") ?? false

        self.path = arguments.getString("path")
        self.name = arguments.getString("name")
        self.select = arguments.getString("select")
        self.ensureExpanded = arguments.getBool("ensure_expanded") ?? false

        self.force = arguments.getBool("force")
    }

    var hasAnyTargeting: Bool {
        !(self.app?.isEmpty ?? true) ||
            self.pid != nil ||
            self.windowId != nil ||
            !(self.windowTitle?.isEmpty ?? true) ||
            self.windowIndex != nil
    }

    func requireButton() throws -> String {
        guard let button, !button.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DialogToolInputError.missingForAction(action: .click, field: "button")
        }
        return button
    }

    struct DialogInputRequest {
        let text: String
        let fieldIdentifier: String?
        let clearExisting: Bool
    }

    func requireInputRequest() throws -> DialogInputRequest {
        guard let text, !text.isEmpty else {
            throw DialogToolInputError.missingForAction(action: .input, field: "text")
        }

        let identifier: String? = if let field, !field.isEmpty {
            field
        } else if let fieldIndex {
            String(fieldIndex)
        } else {
            nil
        }

        return DialogInputRequest(text: text, fieldIdentifier: identifier, clearExisting: self.clear)
    }

    struct DialogFileRequest {
        let path: String?
        let name: String?
        let select: String?
        let ensureExpanded: Bool
    }

    func fileRequest() -> DialogFileRequest {
        DialogFileRequest(path: self.path, name: self.name, select: self.select, ensureExpanded: self.ensureExpanded)
    }

    func targetSelector() throws -> DialogTargetSelector {
        try DialogTargetSelector(
            applicationIdentifier: self.app,
            processIdentifier: self.pid.flatMap(Int32.init(exactly:)),
            windowID: self.windowId,
            windowTitle: self.windowTitle,
            windowIndex: self.windowIndex)
    }
}
