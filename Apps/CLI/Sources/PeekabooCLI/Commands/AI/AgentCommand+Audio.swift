//
//  AgentCommand+Audio.swift
//  PeekabooCLI
//

import Darwin
import Dispatch
import Foundation
import PeekabooCore

@available(macOS 14.0, *)
extension AgentCommand {
    func buildExecutionTask() async throws -> String {
        if self.audio || self.audioFile != nil {
            return try await self.processAudioInput()
        }

        guard let providedTask = self.task else {
            try self.failAgentCommand(message: "Task argument is required", code: .VALIDATION_ERROR)
        }
        return providedTask
    }

    private func processAudioInput() async throws -> String {
        self.logAudioStartMessage()
        let audioService = self.services.audioInput

        do {
            let transcript = try await self.transcribeAudio(using: audioService)
            self.logTranscriptionSuccess(transcript)
            return self.composeExecutionTask(with: transcript)
        } catch let error as CancellationError {
            throw error
        } catch {
            try self.failAgentCommand(
                message: AgentMessages.Audio.processingError(error),
                code: .AGENT_ERROR)
        }
    }

    private func logAudioStartMessage() {
        guard !self.jsonOutput, !self.quiet else { return }
        if let audioPath = self.audioFile {
            print("\(TerminalColor.cyan)🎙️ Processing audio file: \(audioPath)\(TerminalColor.reset)")
        } else {
            let recordingMessage = [
                "\(TerminalColor.cyan)🎙️ Starting audio recording...",
                " (Press Ctrl+C to stop)\(TerminalColor.reset)",
            ].joined()
            print(recordingMessage)
        }
    }

    private func transcribeAudio(using audioService: AudioInputService) async throws -> String {
        if let audioPath = self.audioFile {
            let url = URL(fileURLWithPath: PathResolver.expandPath(audioPath))
            return try await audioService.transcribeAudioFile(url)
        } else {
            try await audioService.startRecording()
            return try await self.captureMicrophoneAudio(using: audioService)
        }
    }

    private func captureMicrophoneAudio(using audioService: AudioInputService) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
                signalSource.setEventHandler {
                    signalSource.cancel()
                    Task { @MainActor in
                        do {
                            let transcript = try await audioService.stopRecording()
                            continuation.resume(returning: transcript)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                signalSource.resume()
            }
        } onCancel: {
            Task { @MainActor in
                _ = try? await audioService.stopRecording()
            }
        }
    }

    private func logTranscriptionSuccess(_ transcript: String) {
        guard !self.jsonOutput, !self.quiet else { return }
        let message = [
            "\(TerminalColor.green)\(AgentDisplayTokens.Status.success) Transcription complete",
            "\(TerminalColor.reset)",
        ].joined()
        print(message)
        print("\(TerminalColor.gray)Transcript: \(transcript.prefix(100))...\(TerminalColor.reset)")
    }

    private func composeExecutionTask(with transcript: String) -> String {
        Self.composeExecutionTask(providedTask: self.task, transcript: transcript)
    }

    static func composeExecutionTask(providedTask: String?, transcript: String) -> String {
        guard let providedTask, !providedTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return transcript
        }
        return "\(providedTask)\n\nAudio transcript:\n\(transcript)"
    }
}
