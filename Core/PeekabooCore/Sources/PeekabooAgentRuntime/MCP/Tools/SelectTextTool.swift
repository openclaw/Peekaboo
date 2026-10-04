import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

public struct SelectTextTool: MCPTool {
    public let name = "select_text"
    private let context: MCPToolContext

    public var description: String {
        "Select literal text or place a caret before/after it in an observed element without activating, " +
            "focusing, typing, or using the clipboard. Requires a fresh exact-window snapshot and settable " +
            "AXSelectedTextRange; refuses missing or ambiguous matches. Prefix/suffix are immediately adjacent context."
    }

    public var inputSchema: Value {
        SchemaBuilder.object(properties: [
            "on": SchemaBuilder.string(description: "Observed element ID or unique query."),
            "text": SchemaBuilder.string(description: "Nonempty literal text to match, without Unicode normalization."),
            "prefix": SchemaBuilder.string(description: "Literal context immediately before the match."),
            "suffix": SchemaBuilder.string(description: "Literal context immediately after the match."),
            "selection_type": SchemaBuilder.string(
                description: "Select text or place a caret at either boundary.",
                enum: TextSelectionType.allCases.map(\.rawValue),
                default: "text"),
            "snapshot": SchemaBuilder.string(description: "Fresh exact-window snapshot ID; latest when omitted."),
        ], required: ["on", "text"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        var snapshotId: String?
        do {
            guard let target = arguments.getString("on")?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !target.isEmpty, let text = arguments.getString("text"), !text.isEmpty,
                  let mode = TextSelectionType(rawValue: arguments.getString("selection_type") ?? "text")
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "select_text requires on, nonempty text, and a valid selection_type.")
            }
            for key in ["prefix", "suffix", "selection_type", "snapshot"] {
                if arguments.getValue(for: key) != nil, arguments.getString(key) == nil {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .invalidRequest, message: "\(key) must be a string.")
                }
            }
            guard let automation = self.context.automation as? any ElementActionAutomationServiceProtocol,
                  automation.supportsTextSelection
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible, message: "This host does not support receipted text selection.")
            }
            guard let snapshot = await self.context.uiSnapshots.getSnapshot(id: arguments.getString("snapshot")) else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable, message: "Run see or inspect_ui for a fresh exact-window snapshot.")
            }
            snapshotId = snapshot.id
            let expected = try MCPElementActionSnapshotAuthority.expectedTargetIdentity(
                snapshot,
                requireExactWindow: true)
            let request = TextSelectionRequest(
                text: text,
                prefix: arguments.getString("prefix"),
                suffix: arguments.getString("suffix"),
                selectionType: mode)
            let (result, invalidated) = try await MCPElementActionSnapshotAuthority.withConfirmedMutation(
                snapshot: snapshot,
                expectedTarget: expected,
                context: self.context,
                operation: "Select text",
                mutate: {
                    try await automation.selectText(
                        target: target,
                        request: request,
                        snapshotId: snapshot.id)
                },
                validateResult: { result in
                    guard result.payload.matchesTextSelection(target: target, request: request) else {
                        throw DesktopActionFailure.indeterminate(
                            delivery: result.outcome?.delivery,
                            evidence: .completionUnknown,
                            unitCount: result.outcome?.dispatchState.unitCount ?? .one,
                            message: "The text selection result did not match the request.",
                            hint: "Observe the exact target before retrying.")
                    }
                })
            guard let selection = result.payload.textSelection
            else { throw PeekabooError.invalidInput("Missing selection") }
            let range = selection.selectedRange
            var meta: [String: Value] = [
                "target": .string(target), "selection_type": .string(mode.rawValue),
                "selected_text_range": .object(["location": .int(range.location), "length": .int(range.length)]),
                "matched_text_range": .object([
                    "location": .int(selection.matchedRange.location), "length": .int(selection.matchedRange.length),
                ]),
            ]
            if let invalidated {
                meta["invalidated_snapshot"] = .string(invalidated)
            }
            meta = try MCPDesktopTargetMetadataProjector.fields(result.targetIdentity, merging: meta)
            return try ToolResponse.text(
                "Text selection \(target): UTF-16 location \(range.location), length \(range.length)",
                meta: MCPToolResponseMetadataProjector.metadata(merging: meta, outcome: result.outcome))
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: snapshotId,
                additionalFields: ObservationActionResultSupport.standardErrorFields(failure))
        } catch {
            return ToolResponse.error("Text selection failed: \(error.localizedDescription)")
        }
    }
}
