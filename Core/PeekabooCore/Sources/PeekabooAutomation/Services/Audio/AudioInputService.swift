//
//  AudioInputService.swift
//  PeekabooCore
//

import Foundation
import Observation
import os.log
import Tachikoma // For TachikomaError
import TachikomaAudio

/// Error types for audio input operations
public enum AudioInputError: LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case fileNotFound(URL)
    case unsupportedFileType(String)
    case fileTooLarge(Int)
    case microphonePermissionDenied
    case audioSessionError(String)
    case transcriptionFailed(String)
    case apiKeyMissing

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "Already recording audio"
        case .notRecording:
            "Not currently recording"
        case let .fileNotFound(url):
            "Audio file not found at \(url.path)"
        case let .unsupportedFileType(type):
            "Unsupported audio file type: \(type)"
        case let .fileTooLarge(size):
            "Audio file too large: \(size) bytes (max 25MB)"
        case .microphonePermissionDenied:
            "Microphone permission denied"
        case let .audioSessionError(message):
            "Audio session error: \(message)"
        case let .transcriptionFailed(message):
            "Transcription failed: \(message)"
        case .apiKeyMissing:
            "OpenAI API key is required for transcription"
        }
    }
}

/// Service for handling audio input and transcription
@MainActor
@Observable
public final class AudioInputService {
    // MARK: - Properties

    @ObservationIgnored
    private let aiService: PeekabooAIService
    @ObservationIgnored
    private let credentialProvider: any AudioTranscriptionCredentialProviding
    @ObservationIgnored
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "AudioInputService")
    @ObservationIgnored
    private let recorder: any AudioRecorderProtocol
    @ObservationIgnored
    private nonisolated(unsafe) var stateObservationTask: Task<Void, Never>?

    public private(set) var isRecording = false
    public private(set) var recordingDuration: TimeInterval = 0

    /// Maximum file size: 25MB (OpenAI Whisper limit)
    @ObservationIgnored
    private let maxFileSize = 25 * 1024 * 1024

    /// Supported audio formats for transcription
    @ObservationIgnored
    private let supportedExtensions = ["wav", "mp3", "m4a", "mp4", "mpeg", "mpga", "webm"]

    // MARK: - Initialization

    public convenience init(aiService: PeekabooAIService) {
        self.init(
            aiService: aiService,
            credentialProvider: ConfigurationCredentialProvider(),
            recorder: AudioRecorder())
    }

    init(
        aiService: PeekabooAIService,
        credentialProvider: any AudioTranscriptionCredentialProviding,
        recorder: any AudioRecorderProtocol)
    {
        self.aiService = aiService
        self.credentialProvider = credentialProvider
        self.recorder = recorder
    }

    deinit {
        self.stateObservationTask?.cancel()
    }

    // MARK: - Public Properties

    /// Check if audio recording is available
    public var isAvailable: Bool {
        self.recorder.isAvailable
    }

    // MARK: - Private Methods

    private func observeRecorderState() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            self.isRecording = self.recorder.isRecording
            self.recordingDuration = self.recorder.recordingDuration

            if !self.recorder.isRecording {
                return
            }
        }
    }

    private func startStateObservationIfNeeded() {
        guard self.stateObservationTask == nil else { return }
        self.stateObservationTask = Task { @MainActor [weak self] in
            await self?.observeRecorderState()
        }
    }

    private func stopStateObservation() {
        self.stateObservationTask?.cancel()
        self.stateObservationTask = nil
    }

    // MARK: - Recording Methods

    /// Start recording audio from the microphone
    public func startRecording() async throws {
        // Start recording audio from the microphone
        do {
            try await self.recorder.startRecording()
            self.isRecording = true
            self.startStateObservationIfNeeded()
            self.logger.info("Started audio recording")
        } catch let error as AudioRecordingError {
            // Convert AudioRecordingError to AudioInputError
            switch error {
            case .alreadyRecording:
                throw AudioInputError.alreadyRecording
            case .microphonePermissionDenied:
                throw AudioInputError.microphonePermissionDenied
            case let .audioEngineError(message):
                throw AudioInputError.audioSessionError(message)
            default:
                throw AudioInputError.audioSessionError(error.localizedDescription)
            }
        } catch {
            throw AudioInputError.audioSessionError(error.localizedDescription)
        }
    }

    /// Stop recording and return the transcription
    public func stopRecording() async throws -> String {
        // Stop recording and return the transcription
        do {
            let audioData = try await recorder.stopRecording()
            self.isRecording = false
            self.recordingDuration = 0
            self.stopStateObservation()
            self.logger.info("Stopped audio recording")

            // Transcribe the recorded audio using TachikomaAudio
            let credential = try self.transcriptionCredential()
            return try await self.aiService.transcribeAudio(audioData, openAICredential: credential)
        } catch let error as AudioRecordingError {
            // Convert AudioRecordingError to AudioInputError
            switch error {
            case .notRecording:
                throw AudioInputError.notRecording
            case .noRecordingAvailable:
                throw AudioInputError.audioSessionError("No recording available")
            default:
                throw AudioInputError.audioSessionError(error.localizedDescription)
            }
        } catch let error as AudioInputError {
            throw error
        } catch let error as TachikomaError {
            // Convert TachikomaError to AudioInputError
            switch error {
            case let .authenticationFailed(message) where message.contains("API_KEY"):
                throw AudioInputError.apiKeyMissing
            case let .invalidInput(message), let .apiError(message):
                throw AudioInputError.transcriptionFailed(message)
            default:
                throw AudioInputError.transcriptionFailed(error.localizedDescription)
            }
        } catch {
            throw AudioInputError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Cancel recording without transcription
    public func cancelRecording() async {
        // Cancel recording without transcription
        await self.recorder.cancelRecording()
        self.isRecording = false
        self.stopStateObservation()
        self.logger.info("Cancelled audio recording")
    }

    // MARK: - Transcription Methods

    /// Transcribe an audio file using OpenAI Whisper
    public func transcribeAudioFile(_ url: URL) async throws -> String {
        // Validate file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioInputError.fileNotFound(url)
        }

        // Validate file extension
        let fileExtension = url.pathExtension.lowercased()
        guard self.supportedExtensions.contains(fileExtension) else {
            throw AudioInputError.unsupportedFileType(fileExtension)
        }

        // Validate file size
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let fileSize = attributes[.size] as? Int {
            guard fileSize <= self.maxFileSize else {
                throw AudioInputError.fileTooLarge(fileSize)
            }
        }

        let credential = try self.transcriptionCredential()

        // Use AI service to transcribe
        do {
            let transcription = try await aiService.transcribeAudio(at: url, openAICredential: credential)
            self.logger.info("Successfully transcribed audio file")
            return transcription
        } catch let audioError as AudioInputError {
            throw audioError
        } catch {
            self.logger.error("Transcription failed: \(error)")
            throw AudioInputError.transcriptionFailed(error.localizedDescription)
        }
    }

    private func transcriptionCredential() throws -> String {
        guard let key = self.credentialProvider.currentOpenAIKey(),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AudioInputError.apiKeyMissing
        }
        return key
    }
}

// MARK: - Credential Provider

protocol AudioTranscriptionCredentialProviding: Sendable {
    func currentOpenAIKey() -> String?
}

struct ConfigurationCredentialProvider: AudioTranscriptionCredentialProviding {
    func currentOpenAIKey() -> String? {
        ConfigurationManager.shared.getOpenAITranscriptionCredential()
    }
}

// MARK: - PeekabooAIService Extension

extension PeekabooAIService {
    public func transcribeAudio(_ audioData: AudioData, openAICredential: String? = nil) async throws -> String {
        let configuration = self.audioConfiguration(openAICredential: openAICredential)
        return try await transcribe(audioData, configuration: configuration)
    }

    /// Transcribe audio using TachikomaAudio's transcription API
    public func transcribeAudio(at url: URL, openAICredential: String? = nil) async throws -> String {
        let configuration = self.audioConfiguration(openAICredential: openAICredential)
        // Use TachikomaAudio's convenient transcribe function
        do {
            return try await transcribe(contentsOf: url, configuration: configuration)
        } catch {
            // Convert errors to AudioInputError for compatibility
            if let tachikomaError = error as? TachikomaError {
                switch tachikomaError {
                case let .authenticationFailed(message) where message.contains("API_KEY"):
                    throw AudioInputError.apiKeyMissing
                case let .invalidInput(message):
                    throw AudioInputError.transcriptionFailed(message)
                case let .apiError(message):
                    throw AudioInputError.transcriptionFailed(message)
                default:
                    throw AudioInputError.transcriptionFailed(error.localizedDescription)
                }
            }
            throw AudioInputError.transcriptionFailed(error.localizedDescription)
        }
    }

    private func audioConfiguration(openAICredential: String?) -> TachikomaConfiguration {
        let configuration = TachikomaConfiguration(loadFromEnvironment: true)
        if let openAICredential, !openAICredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configuration.setAPIKey(openAICredential, for: .openai)
        }
        return configuration
    }
}
