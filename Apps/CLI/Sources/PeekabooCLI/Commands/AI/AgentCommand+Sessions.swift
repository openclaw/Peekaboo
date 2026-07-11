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
}

@available(macOS 14.0, *)
extension AgentCommand {
    struct ResumeAgentSessionRequest {
        let sessionId: String
        let task: String
        let requestedModel: LanguageModel?
        let maxSteps: Int
        let queueMode: QueueMode
    }

    func handleSessionResumption(
        _ agentService: PeekabooAgentService,
        requestedModel: LanguageModel?,
        maxSteps: Int,
        queueMode: QueueMode
    ) async throws -> Bool {
        if let sessionId = self.resumeSession {
            guard let continuationTask = self.task else {
                self.printMissingTaskError(
                    message: "Task argument required when resuming session",
                    usage: "Usage: peekaboo agent --resume-session <session-id> \"<continuation-task>\""
                )
                return true
            }
            try await self.resumeAgentSession(
                agentService,
                request: ResumeAgentSessionRequest(
                    sessionId: sessionId,
                    task: continuationTask,
                    requestedModel: requestedModel,
                    maxSteps: maxSteps,
                    queueMode: queueMode
                )
            )
            return true
        }

        if self.resume {
            guard let continuationTask = self.task else {
                self.printMissingTaskError(
                    message: "Task argument required when resuming",
                    usage: "Usage: peekaboo agent --resume \"<continuation-task>\""
                )
                return true
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
                        queueMode: queueMode
                    )
                )
            } else {
                if self.jsonOutput {
                    let error = ["success": false, "error": "No sessions found to resume"] as [String: Any]
                    let jsonData = try JSONSerialization.data(withJSONObject: error, options: .prettyPrinted)
                    print(String(data: jsonData, encoding: .utf8) ?? "{}")
                } else {
                    print("\(TerminalColor.red)Error: No sessions found to resume\(TerminalColor.reset)")
                }
            }
            return true
        }

        return false
    }

    func printMissingTaskError(message: String, usage: String) {
        if self.jsonOutput {
            let error = ["success": false, "error": message] as [String: Any]
            if let jsonData = try? JSONSerialization.data(withJSONObject: error, options: .prettyPrinted),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            } else {
                print("{\"success\":false,\"error\":\"\(message)\"}")
            }
        } else {
            print("\(TerminalColor.red)Error: \(message)\(TerminalColor.reset)")
            if !usage.isEmpty {
                print(usage)
            }
        }
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
                messageCount: summary.messageCount
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
        let sessionData = sessions.map { session in
            [
                "id": session.id,
                "createdAt": ISO8601DateFormatter().string(from: session.created),
                "updatedAt": ISO8601DateFormatter().string(from: session.lastModified),
                "messageCount": session.messageCount
            ]
        }
        let response = ["success": true, "sessions": sessionData] as [String: Any]
        if let jsonData = try? JSONSerialization.data(withJSONObject: response, options: .prettyPrinted) {
            print(String(data: jsonData, encoding: .utf8) ?? "{}")
        }
    }

    private func printSessionsList(_ sessions: [AgentSessionInfo]) {
        let headerLine = [
            "\(TerminalColor.cyan)\(TerminalColor.bold)Agent Sessions:\(TerminalColor.reset)",
            "\n"
        ].joined()
        print(headerLine)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        for (index, session) in sessions.prefix(10).indexed() {
            self.printSessionLine(index: index, session: session, dateFormatter: dateFormatter)
            if index < sessions.count - 1 {
                print()
            }
        }

        if sessions.count > 10 {
            print([
                "\n",
                "\(TerminalColor.dim)... and \(sessions.count - 10) more sessions\(TerminalColor.reset)"
            ].joined())
        }

        let resumeHintLine = [
            "\n",
            "\(TerminalColor.dim)To resume: peekaboo agent --resume <session-id>",
            " \"<continuation>\"\(TerminalColor.reset)"
        ].joined()
        print(resumeHintLine)
    }

    private func printSessionLine(index: Int, session: AgentSessionInfo, dateFormatter: DateFormatter) {
        let timeAgo = formatTimeAgo(session.lastModified)
        let sessionLine = [
            "\(TerminalColor.blue)\(index + 1).\(TerminalColor.reset)",
            " ",
            "\(TerminalColor.bold)\(session.id.prefix(8))\(TerminalColor.reset)"
        ].joined()
        print(sessionLine)
        print("   Messages: \(session.messageCount)")
        print("   Last activity: \(timeAgo)")
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
                "\n"
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
                eventDelegate: streamingDelegate
            )
            self.displayResult(result, delegate: outputDelegate)
        } catch {
            if outputDelegate?.hasReceivedError != true {
                self.printAgentExecutionError("Failed to resume session: \(error.localizedDescription)")
            }
            throw ExitCode.failure
        }
    }
}
