import Commander
import Foundation
import PeekabooAgentRuntime
import PeekabooCore
import PeekabooFoundation
import Tachikoma
import TauTUI

/// Temporary session info struct until PeekabooAgentService implements session management
struct AgentSessionInfo: Codable {
    let id: String
    let task: String
    let created: Date
    let lastModified: Date
    let messageCount: Int
    let status: String
    let toolExecutionPolicy: String
}

@available(macOS 14.0, *)
extension AgentCommand {
    struct ResumeAgentSessionRequest {
        let sessionId: String
        let task: String
        let requestedModel: LanguageModel?
        let maxSteps: Int
        let queueMode: QueueMode
        let requestedToolExecutionPolicy: MCPToolExecutionPolicy?
    }

    func validateSessionOptions() throws {
        guard self.noCache else { return }
        guard !self.resume, self.resumeSession == nil, !self.listSessions else {
            throw PeekabooError.invalidInput(
                "--no-cache cannot be combined with resume or sessions mode."
            )
        }
    }

    func requireRequestedSession(_ agentService: PeekabooAgentService) async throws {
        if let sessionId = self.resumeSession {
            guard let session = try await agentService.getSessionInfo(sessionId: sessionId) else {
                try self.failAgentCommand(
                    message: "Session not found or expired: \(sessionId)",
                    code: .SESSION_NOT_FOUND
                )
            }
            try self.validateRequestedResumePolicy(session)
        } else if self.resume {
            let sessions = try await agentService.listSessions()
            guard let first = sessions.first else {
                try self.failAgentCommand(
                    message: "No sessions found to resume",
                    code: .SESSION_NOT_FOUND,
                    hint: "Run 'peekaboo agent run \"<task>\"' to start a session."
                )
            }
            if let session = try await agentService.getSessionInfo(sessionId: first.id) {
                try self.validateRequestedResumePolicy(session)
            }
        }
    }

    func handleSessionResumption(
        _ agentService: PeekabooAgentService,
        requestedModel: LanguageModel?,
        maxSteps: Int,
        queueMode: QueueMode
    ) async throws -> Bool {
        if let sessionId = self.resumeSession {
            guard let continuationTask = self.task else {
                try self.failAgentCommand(
                    message: "Task argument required when resuming session",
                    code: .VALIDATION_ERROR,
                    hint: "Usage: peekaboo agent resume <session-id>"
                )
            }
            try await self.resumeAgentSession(
                agentService,
                request: ResumeAgentSessionRequest(
                    sessionId: sessionId,
                    task: continuationTask,
                    requestedModel: requestedModel,
                    maxSteps: maxSteps,
                    queueMode: queueMode,
                    requestedToolExecutionPolicy: self.requestedResumeToolExecutionPolicy
                )
            )
            return true
        }

        if self.resume {
            guard let continuationTask = self.task else {
                try self.failAgentCommand(
                    message: "Task argument required when resuming",
                    code: .VALIDATION_ERROR,
                    hint: "Usage: peekaboo agent resume"
                )
            }

            let sessions = try await agentService.listSessions()

            if let mostRecent = sessions.first {
                try await self.resumeAgentSession(
                    agentService,
                    request: ResumeAgentSessionRequest(
                        sessionId: mostRecent.id,
                        task: continuationTask,
                        requestedModel: requestedModel,
                        maxSteps: maxSteps,
                        queueMode: queueMode,
                        requestedToolExecutionPolicy: self.requestedResumeToolExecutionPolicy
                    )
                )
            } else {
                try self.failAgentCommand(
                    message: "No sessions found to resume",
                    code: .SESSION_NOT_FOUND,
                    hint: "Run 'peekaboo agent run \"<task>\"' to start a session."
                )
            }
            return true
        }

        return false
    }

    @MainActor
    func showSessions(_ agentService: any AgentServiceProtocol) async throws {
        guard let peekabooService = agentService as? PeekabooAgentService else {
            throw PeekabooError.commandFailed("Agent service not properly initialized")
        }

        let sessionSummaries = try await peekabooService.listSessions()
        let sessions = sessionSummaries.map { summary in
            AgentSessionInfo(
                id: summary.id,
                task: summary.summary ?? "Unknown task",
                created: summary.createdAt,
                lastModified: summary.lastAccessedAt,
                messageCount: summary.messageCount,
                status: summary.status.rawValue,
                toolExecutionPolicy: summary.toolExecutionPolicy.rawValue
            )
        }

        guard !sessions.isEmpty else {
            self.printNoAgentSessions()
            return
        }

        if self.jsonOutput {
            self.printSessionsJSON(sessions)
        } else {
            self.printSessionsList(sessions)
        }
    }

    private func printNoAgentSessions() {
        if self.jsonOutput {
            let response = ["success": true, "sessions": []] as [String: Any]
            let jsonData = try? JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
            print(String(data: jsonData ?? Data(), encoding: .utf8) ?? "{}")
        } else {
            print("No agent sessions found.")
        }
    }

    private func printSessionsJSON(_ sessions: [AgentSessionInfo]) {
        let sessionData = sessions.map(self.sessionJSONObject)
        let response = ["success": true, "sessions": sessionData] as [String: Any]
        if let jsonData = try? JSONSerialization.data(withJSONObject: response, options: .prettyPrinted) {
            print(String(data: jsonData, encoding: .utf8) ?? "{}")
        }
    }

    func sessionJSONObject(_ session: AgentSessionInfo) -> [String: Any] {
        [
            "id": session.id,
            "task": session.task,
            "createdAt": ISO8601DateFormatter().string(from: session.created),
            "updatedAt": ISO8601DateFormatter().string(from: session.lastModified),
            "messageCount": session.messageCount,
            "status": session.status,
            "toolExecutionPolicy": session.toolExecutionPolicy,
        ]
    }

    private func printSessionsList(_ sessions: [AgentSessionInfo]) {
        let headerLine = [
            "\(TerminalColor.cyan)\(TerminalColor.bold)Agent Sessions:\(TerminalColor.reset)",
            "\n",
        ].joined()
        print(headerLine)

        for (index, session) in sessions.prefix(10).indexed() {
            self.printSessionLine(index: index, session: session)
            if index < sessions.count - 1 {
                print()
            }
        }

        if sessions.count > 10 {
            print([
                "\n",
                "\(TerminalColor.dim)... and \(sessions.count - 10) more sessions\(TerminalColor.reset)",
            ].joined())
        }

        let resumeHintLine = [
            "\n",
            "\(TerminalColor.dim)To resume: peekaboo agent resume <session-id>",
            "\(TerminalColor.reset)",
        ].joined()
        print(resumeHintLine)
    }

    private func printSessionLine(index: Int, session: AgentSessionInfo) {
        for line in self.sessionDisplayLines(index: index, session: session) {
            print(line)
        }
    }

    func sessionDisplayLines(index: Int, session: AgentSessionInfo) -> [String] {
        let timeAgo = formatTimeAgo(session.lastModified)
        let task = Self.terminalSafeSessionTask(session.task)
        let sessionLine = [
            "\(TerminalColor.blue)\(index + 1).\(TerminalColor.reset)",
            " ",
            "\(TerminalColor.bold)\(task)\(TerminalColor.reset)",
        ].joined()
        let status = self.sessionStatusDescription(session.status)
        return [
            sessionLine,
            "   ID: \(session.id)",
            "   Status: \(status)",
            "   Stored policy maximum: \(session.toolExecutionPolicy)",
            "   Next resume default: background_only",
            "   Messages: \(session.messageCount)",
            "   Last activity: \(timeAgo)",
        ]
    }

    private func sessionStatusDescription(_ status: String) -> String {
        switch status {
        case SessionStatus.active.rawValue:
            "active (saved/resumable; not a live-process signal)"
        case SessionStatus.completed.rawValue:
            "completed (saved/resumable; last run finished)"
        case SessionStatus.failed.rawValue:
            "failed (saved/resumable; last run failed or was cancelled)"
        case SessionStatus.expired.rawValue:
            "expired (past the retention window)"
        default:
            status
        }
    }

    private static func terminalSafeSessionTask(_ task: String) -> String {
        let space = UnicodeScalar(32)!
        let scalars = task.unicodeScalars.compactMap { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return space
            }
            return CharacterSet.controlCharacters.contains(scalar) ? nil : scalar
        }
        let flattened = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return flattened.isEmpty ? "Unknown task" : flattened
    }

    private func resumeAgentSession(
        _ agentService: PeekabooAgentService,
        request: ResumeAgentSessionRequest
    ) async throws {
        if !self.jsonOutput {
            let resumingLine = [
                "\(TerminalColor.cyan)\(TerminalColor.bold)",
                "\(AgentDisplayTokens.Status.info)",
                " Resuming session \(request.sessionId.prefix(8))...",
                "\(TerminalColor.reset)",
                "\n",
            ].joined()
            print(resumingLine)
        }

        let outputDelegate = self.makeDisplayDelegate(for: request.task)
        let streamingDelegate = self.makeStreamingDelegate(using: outputDelegate)
        do {
            let result = try await agentService.continueSession(
                sessionId: request.sessionId,
                userMessage: request.task,
                model: request.requestedModel,
                maxSteps: request.maxSteps,
                dryRun: self.dryRun,
                queueMode: request.queueMode,
                eventDelegate: streamingDelegate,
                requestedToolExecutionPolicy: request.requestedToolExecutionPolicy
            )
            self.displayResult(result, delegate: outputDelegate)
        } catch let error as PeekabooError {
            if case let .sessionNotFound(sessionId) = error {
                try self.failAgentCommand(
                    message: "Session not found or expired: \(sessionId)",
                    code: .SESSION_NOT_FOUND
                )
            }
            if outputDelegate?.hasReceivedError != true {
                self.printAgentExecutionError("Failed to resume session: \(error.localizedDescription)")
            }
            throw ExitCode.failure
        } catch {
            if outputDelegate?.hasReceivedError != true {
                self.printAgentExecutionError("Failed to resume session: \(error.localizedDescription)")
            }
            throw ExitCode.failure
        }
    }

    private func validateRequestedResumePolicy(_ session: AgentSession) throws {
        guard self.requestedResumeToolExecutionPolicy == .foregroundAllowed,
              session.effectiveToolExecutionPolicy != .foregroundAllowed
        else {
            return
        }
        try self.failAgentCommand(
            message: "Session \(session.id) is background-only and cannot be broadened while resuming.",
            code: .VALIDATION_ERROR,
            hint: "Start a new session with --allow-foreground when foreground interaction is intentionally authorized."
        )
    }
}
