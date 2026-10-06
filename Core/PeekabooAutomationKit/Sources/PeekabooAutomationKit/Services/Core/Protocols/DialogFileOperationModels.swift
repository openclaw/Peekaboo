import Foundation
import PeekabooFoundation

/// One host-owned foreground file operation, planned before focus against the complete caller selector.
public struct DialogFileExecutionRequest: Sendable, Codable, Equatable {
    public let target: DialogTargetSelector
    public let path: String?
    public let filename: String?
    public let actionButton: String?
    public let ensureExpanded: Bool
    public let focus: DialogForegroundFocusPolicy

    public init(
        target: DialogTargetSelector,
        path: String? = nil,
        filename: String? = nil,
        actionButton: String? = nil,
        ensureExpanded: Bool = false,
        focus: DialogForegroundFocusPolicy = DialogForegroundFocusPolicy()) throws
    {
        guard target.hasTarget else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Exact file-dialog execution requires an app, PID, or window target.",
                hint: "List the dialog and provide its owner or exact parent window.")
        }
        try focus.validate(operation: "File dialog")
        self.target = target
        self.path = path
        self.filename = filename
        self.actionButton = actionButton
        self.ensureExpanded = ensureExpanded
        self.focus = focus
    }

    private enum CodingKeys: String, CodingKey {
        case target, path, filename, actionButton, ensureExpanded, focus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            target: container.decode(DialogTargetSelector.self, forKey: .target),
            path: container.decodeIfPresent(String.self, forKey: .path),
            filename: container.decodeIfPresent(String.self, forKey: .filename),
            actionButton: container.decodeIfPresent(String.self, forKey: .actionButton),
            ensureExpanded: container.decode(Bool.self, forKey: .ensureExpanded),
            focus: container.decode(DialogForegroundFocusPolicy.self, forKey: .focus))
    }
}
