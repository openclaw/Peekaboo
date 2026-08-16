import Foundation
import Tachikoma
import TachikomaMCP

/// QueueMode mirrors pi-mono's message queue behavior: send queued user messages
/// either one at a time per turn, or all queued together before the next turn.
public enum QueueMode: String, Sendable {
    case oneAtATime = "one-at-a-time"
    case all
}

enum AgentTurnBoundarySignal: Equatable, Sendable {
    case continueNextStep(reason: String)
    case stopAgent(reason: String)

    var reason: String {
        switch self {
        case let .continueNextStep(reason), let .stopAgent(reason): reason
        }
    }
}

@MainActor
final class AgentTurnBoundary {
    enum Decision: Equatable {
        case continueTurn
        case continueNextStep(reason: String)
        case skipUntilCompletionEvidence(reason: String)
        case skipUntilPerception(reason: String)
        case stopAgentAfterSuccessfulTool(reason: String)
    }

    private static let perceiveTools: Set<String> = [
        "capture",
        "image",
        "inspect_ui",
        "see",
        "watch",
    ]

    private static let actionTools: Set<String> = [
        "app",
        "click",
        "dialog",
        "dock",
        "drag",
        "press",
        "menu",
        "move",
        "paste",
        "action",
        "scroll",
        "set_value",
        "space",
        "type",
        "window",
    ]

    private enum PerceptionState {
        case initial
        case perceived
        case required
    }

    private var perceptionState = PerceptionState.initial

    var requiresFreshPerception: Bool {
        self.perceptionState == .required
    }

    private(set) var completionEvidenceIssue: String?
    private var completionEvidenceTarget: CompletionEvidenceTarget?
    private var completionEvidencePredicateFingerprint: String?

    func record(
        toolName: String,
        arguments: [String: AnyAgentToolValue] = [:]) -> Decision
    {
        let normalizedName = Self.normalized(toolName)

        if normalizedName == "done" {
            if let completionEvidenceIssue {
                return .skipUntilCompletionEvidence(reason: completionEvidenceIssue)
            }
            let message = arguments["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = if let message, !message.isEmpty {
                message
            } else {
                "Task completed successfully."
            }
            return .stopAgentAfterSuccessfulTool(reason: reason)
        }

        if normalizedName == "need_info",
           let question = arguments["question"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !question.isEmpty
        {
            return .stopAgentAfterSuccessfulTool(reason: "Need more information: \(question)")
        }

        if Self.perceiveTools.contains(normalizedName) {
            return .continueTurn
        }

        guard Self.isMutatingActionTool(normalizedName, arguments: arguments) else {
            return .continueTurn
        }

        switch self.perceptionState {
        case .initial:
            self.perceptionState = .required
            return .continueNextStep(
                reason: "Stopped after \(normalizedName); call `see` before the next UI action.")
        case .perceived:
            self.perceptionState = .required
            return .continueNextStep(
                reason: "Stopped after \(normalizedName); call `see` again before the next UI action.")
        case .required:
            return .skipUntilPerception(
                reason: "Skipped \(normalizedName); call `see` successfully before another UI action.")
        }
    }

    /// Conditional calls can be read-only, refused before dispatch, or mutating under one tool name.
    /// Only a complete canonical outcome can therefore create result-derived fresh-perception debt.
    func recordResult(
        toolName: String,
        result: AnyAgentToolValue?) -> Decision
    {
        let normalizedName = Self.normalized(toolName)
        guard let result,
              case let .valid(projection) = AgentToolResultSemantics.actionOutcomeResolution(from: result),
              projection.requiresFreshObservation
        else {
            return .continueTurn
        }

        self.perceptionState = .required
        return .continueNextStep(
            reason: "Stopped after \(normalizedName); call `see` before the next UI action.")
    }

    func recordSuccessfulCompletion(
        toolName: String,
        arguments: [String: AnyAgentToolValue] = [:],
        result: AnyAgentToolValue? = nil)
    {
        let normalizedName = Self.normalized(toolName)
        if normalizedName == "verify_state" {
            guard let completionEvidenceTarget = self.completionEvidenceTarget,
                  let receipt = VerificationReceipt(result: result)
            else { return }

            guard completionEvidenceTarget.matches(receipt.target) else {
                self.completionEvidenceIssue = Self.mismatchedCompletionEvidenceReason
                return
            }
            guard let requiredFingerprint = self.completionEvidencePredicateFingerprint else {
                self.completionEvidencePredicateFingerprint = receipt.predicateFingerprint
                switch receipt.status {
                case .satisfied where receipt.allPredicatesSatisfied:
                    self.completionEvidenceIssue = Self.committedSatisfiedCompletionEvidenceReason
                case .satisfied, .unknown:
                    self.completionEvidenceIssue = Self.incompleteCompletionEvidenceReason
                case .unsatisfied:
                    self.completionEvidenceIssue = Self.unsatisfiedCompletionEvidenceReason
                }
                return
            }
            if requiredFingerprint != receipt.predicateFingerprint {
                self.completionEvidenceIssue = Self.mismatchedCompletionPredicateReason
                return
            }

            switch receipt.status {
            case .satisfied where receipt.allPredicatesSatisfied:
                self.completionEvidenceIssue = nil
                self.completionEvidenceTarget = nil
                self.completionEvidencePredicateFingerprint = nil
            case .satisfied:
                self.completionEvidenceIssue = Self.incompleteCompletionEvidenceReason
            case .unsatisfied:
                self.completionEvidenceIssue = Self.unsatisfiedCompletionEvidenceReason
            case .unknown:
                self.completionEvidenceIssue = Self.incompleteCompletionEvidenceReason
            }
            return
        }

        guard Self.perceiveTools.contains(normalizedName) else { return }
        self.perceptionState = .perceived
        let resultText = Self.resultText(result)
        if resultText?.contains(
            AgentToolMCPBridge.incompleteVisualEvidenceMarker) == true
        {
            self.completionEvidenceTarget = CompletionEvidenceTarget(observationArguments: arguments)
            self.completionEvidencePredicateFingerprint = nil
            self.completionEvidenceIssue = Self.incompleteCompletionEvidenceReason
        } else {
            self.completionEvidenceTarget = nil
            self.completionEvidencePredicateFingerprint = nil
            self.completionEvidenceIssue = nil
        }
    }

    func restorePerceptionRequired() {
        self.perceptionState = .required
    }

    static func normalized(_ toolName: String) -> String {
        toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func isMutatingActionTool(
        _ normalizedName: String,
        arguments: [String: AnyAgentToolValue]) -> Bool
    {
        guard self.actionTools.contains(normalizedName) else {
            return false
        }

        let toolArguments = ToolArguments(from: AgentToolArguments(arguments))
        return !MCPToolRequestSemantics.isReadOnly(
            toolName: normalizedName,
            arguments: toolArguments)
    }

    private static let incompleteCompletionEvidenceReason =
        "The latest observation did not deliver screenshot pixels to this model and its accessibility evidence " +
        "was incomplete. Call `verify_state` for the exact native postcondition. If verification is unknown, use " +
        "`need_info` to report that more verification is required; do not claim that unseen state is present or absent."

    private static let unsatisfiedCompletionEvidenceReason =
        "The exact native postcondition is unsatisfied. Retry the requested action or use `need_info` to report " +
        "that it could not be completed; do not claim success."

    private static let committedSatisfiedCompletionEvidenceReason =
        "The exact native postcondition has been committed for completion evidence, but its first satisfied " +
        "receipt cannot complete the proof. Repeat `verify_state` with the exact same target and predicates. " +
        "Only a later identical satisfied receipt can authorize completion."

    private static let mismatchedCompletionEvidenceReason =
        "The verification did not target the same app/PID and exact window as the incomplete observation. " +
        "Verify the original target or use `need_info`; do not claim its state from unrelated evidence."

    private static let mismatchedCompletionPredicateReason =
        "The verification checked a different native predicate than the postcondition already bound to " +
        "this incomplete observation. Verify that exact postcondition or use `need_info`; unrelated state on the " +
        "same window does not prove completion."

    private static func resultText(_ result: AnyAgentToolValue?) -> String? {
        guard let result else { return nil }
        if let string = result.stringValue {
            return string
        }
        guard let json = try? result.toJSON(),
              JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    private enum CompletionEvidenceTarget: Equatable {
        case application(String, windowID: Int?)
        case pid(Int, windowID: Int?)

        init?(observationArguments: [String: AnyAgentToolValue]) {
            let windowID = observationArguments["window_id"]?.intValue
            guard let rawTarget = observationArguments["app_target"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !rawTarget.isEmpty
            else {
                return nil
            }

            if rawTarget.lowercased().hasPrefix("pid:"),
               let pid = Int(rawTarget.dropFirst(4)), pid > 0
            {
                self = .pid(pid, windowID: windowID)
            } else if rawTarget.lowercased() != "frontmost", !rawTarget.lowercased().hasPrefix("screen:") {
                self = .application(rawTarget.lowercased(), windowID: windowID)
            } else {
                return nil
            }
        }

        func matches(_ target: VerificationReceipt.Target) -> Bool {
            switch self {
            case let .application(app, windowID):
                target.application?.lowercased() == app && target.windowID == windowID
            case let .pid(pid, windowID):
                target.pid == pid && target.windowID == windowID
            }
        }
    }

    private struct VerificationReceipt {
        enum Status: String {
            case satisfied
            case unsatisfied
            case unknown
        }

        struct Target {
            let application: String?
            let pid: Int?
            let windowID: Int?
        }

        let status: Status
        let target: Target
        let predicateFingerprint: String
        let allPredicatesSatisfied: Bool

        init?(result: AnyAgentToolValue?) {
            guard let receipt = result?.objectValue?["verification_receipt"]?.objectValue,
                  let rawStatus = receipt["status"]?.stringValue,
                  let status = Status(rawValue: rawStatus),
                  let target = receipt["target"]?.objectValue,
                  let predicates = receipt["predicates"]?.arrayValue,
                  !predicates.isEmpty,
                  let predicateFingerprint = Self.predicateFingerprint(predicates)
            else {
                return nil
            }
            self.status = status
            self.target = Target(
                application: target["application"]?.stringValue,
                pid: target["pid"]?.intValue,
                windowID: target["window_id"]?.intValue)
            self.predicateFingerprint = predicateFingerprint
            self.allPredicatesSatisfied = predicates.allSatisfy {
                $0.objectValue?["status"]?.stringValue == Status.satisfied.rawValue
            }
        }

        private static func predicateFingerprint(_ predicates: [AnyAgentToolValue]) -> String? {
            let canonical = predicates.compactMap { predicate -> [String: Any]? in
                guard var object = try? predicate.toJSON() as? [String: Any] else { return nil }
                object.removeValue(forKey: "status")
                object.removeValue(forKey: "detail")
                object.removeValue(forKey: "observed")
                return object
            }
            guard canonical.count == predicates.count,
                  JSONSerialization.isValidJSONObject(canonical),
                  let data = try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])
            else {
                return nil
            }
            return data.base64EncodedString()
        }
    }
}
