import AVFoundation
import Foundation
import Observation
import Speech
import Tachikoma
import TachikomaAudio

/// Provides speech-to-text capabilities for voice-driven automation.
///
/// `SpeechRecognizer` enables users to interact with Peekaboo using voice commands.
/// It supports multiple recognition methods:
/// - Native macOS Speech framework (no API key required)
/// - OpenAI Whisper API for enhanced accuracy
/// - Direct audio streaming to AI providers (for models that support audio input)
///
/// ## Overview
///
/// The speech recognizer:
/// - Uses native macOS Speech framework by default (no API key required)
/// - Optionally uses OpenAI Whisper for better accuracy
/// - Can record raw audio for direct submission to AI providers
/// - Requests and manages microphone permissions
/// - Provides real-time speech transcription
/// - Handles recognition errors gracefully
/// - Supports continuous listening for voice commands
///
/// ## Topics
///
/// ### State Management
///
/// - ``isListening``
/// - ``transcript``
/// - ``isAvailable``
/// - ``error``
///
/// ### Recognition Control
///
/// - ``requestAuthorization()``
/// - ``startListening()``
/// - ``stopListening()``
///
/// ### Delegate Conformance
///
/// Conforms to `SFSpeechRecognizerDelegate` for availability updates.
/// Recognition modes available for speech input
public enum RecognitionMode: String, CaseIterable {
    case native = "Native macOS"
    case whisper = "OpenAI Whisper"
    case tachikoma = "Tachikoma Audio API"
    case direct = "Direct to AI"

    var requiresOpenAIKey: Bool {
        switch self {
        case .native, .direct:
            false
        case .whisper, .tachikoma:
            true
        }
    }

    var description: String {
        switch self {
        case .native:
            "Built-in macOS speech recognition (no API key required)"
        case .whisper:
            "OpenAI Whisper for better accuracy (requires OpenAI key)"
        case .tachikoma:
            "Tachikoma unified audio API with multiple provider support"
        case .direct:
            "Send audio directly to AI provider for native processing"
        }
    }
}

@MainActor
protocol SpeechAudioRecording: AnyObject {
    var isRecording: Bool { get }
    var transcript: String { get }
    var error: (any Error)? { get }

    func startRecording() throws
    func stopRecording()
}

extension AudioRecorder: SpeechAudioRecording {}

@Observable
@MainActor
final class SpeechRecognizer: NSObject, SFSpeechRecognizerDelegate {
    var isListening = false
    var transcript = ""
    var isAvailable = false
    var error: (any Error)?

    /// Recognition mode
    var recognitionMode: RecognitionMode = .native

    // Native speech recognition
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // Optional Whisper-based recorder for enhanced accuracy
    private var audioRecorder: (any SpeechAudioRecording)?
    private let settings: PeekabooSettings

    // For direct audio recording
    private var directAudioRecorder: AVAudioRecorder?
    private var directAudioURL: URL?
    private(set) var recordedAudioData: Data?
    private(set) var recordedAudioDuration: TimeInterval?

    // For Tachikoma audio recording
    private var tachikomaAudioRecorder: AVAudioRecorder?
    private var tachikomaAudioURL: URL?
    private var tachikomaAbortSignal: AbortSignal?

    // Whisper recorder observer task, owned by this recognizer.
    private var recorderObserverTask: Task<Void, Never>?
    var hasRecorderObserverTask: Bool {
        self.recorderObserverTask != nil
    }

    init(settings: PeekabooSettings) {
        self.settings = settings
        super.init()

        // Initialize native speech recognizer
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.speechRecognizer?.delegate = self

        // Initialize Whisper recorder if API key available
        if !settings.openAIAPIKey.isEmpty {
            self.audioRecorder = AudioRecorder(settings: settings)
        }

        self.checkAuthorization()
    }

    init(settings: PeekabooSettings, audioRecorder: any SpeechAudioRecording) {
        self.settings = settings
        self.audioRecorder = audioRecorder
        super.init()

        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.speechRecognizer?.delegate = self
        self.checkAuthorization()
    }

    func requestAuthorization() async -> Bool {
        // Request both speech recognition and microphone permissions
        let speechAuthStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        let microphoneAuthStatus = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }

        let authorized = speechAuthStatus && microphoneAuthStatus
        self.isAvailable = authorized
        return authorized
    }

    func startListening() throws {
        guard self.isAvailable else {
            throw SpeechError.notAuthorized
        }

        guard !self.isListening else { return }

        // Reset state
        self.transcript = ""
        self.error = nil
        self.recordedAudioData = nil
        self.recordedAudioDuration = nil

        // Decide which recognition method to use based on mode
        switch self.recognitionMode {
        case .native:
            try self.startNativeRecognition()
        case .whisper:
            if self.audioRecorder != nil {
                try self.startWhisperRecognition()
            } else {
                // Fall back to native if no OpenAI key
                try self.startNativeRecognition()
                self.error = SpeechError.apiKeyRequired
            }
        case .tachikoma:
            if !self.settings.openAIAPIKey.isEmpty {
                try self.startTachikomaRecognition()
            } else {
                // Fall back to native if no OpenAI key
                try self.startNativeRecognition()
                self.error = SpeechError.apiKeyRequired
            }
        case .direct:
            try self.startDirectRecording()
        }

        self.isListening = true
    }

    func stopListening() {
        self.recorderObserverTask?.cancel()
        self.recorderObserverTask = nil
        if self.recognitionMode == .whisper {
            self.audioRecorder?.stopRecording()
        }
        guard self.isListening else { return }

        switch self.recognitionMode {
        case .native:
            // Stop native recognition
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.recognitionRequest?.endAudio()
            self.recognitionTask?.cancel()
            self.recognitionRequest = nil
            self.recognitionTask = nil

        case .whisper:
            break

        case .tachikoma:
            // Stop Tachikoma recording
            self.stopTachikomaRecording()

        case .direct:
            // Stop direct recording
            self.stopDirectRecording()
        }

        self.isListening = false
    }

    private func startNativeRecognition() throws {
        // Cancel any existing task
        self.recognitionTask?.cancel()
        self.recognitionTask = nil

        // On macOS, we don't need to configure AVAudioSession
        // It's iOS-only API

        // Create and configure request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else {
            throw SpeechError.requestCreationFailed
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false // Allow network-based recognition for better accuracy

        // Get input node
        let inputNode = self.audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Install tap
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        // Start recognition task
        self.recognitionTask = self.speechRecognizer?
            .recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }

                var isFinal = false

                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    isFinal = result.isFinal
                }

                if error != nil || isFinal {
                    self.audioEngine.stop()
                    inputNode.removeTap(onBus: 0)

                    self.recognitionRequest = nil
                    self.recognitionTask = nil

                    if let error {
                        self.error = error
                        self.isListening = false
                    }
                }
            }

        // Start audio engine
        self.audioEngine.prepare()
        try self.audioEngine.start()
    }

    private func startWhisperRecognition() throws {
        guard let recorder = audioRecorder else {
            // Fall back to native if Whisper not available
            try self.startNativeRecognition()
            return
        }

        // Start Whisper recording
        try recorder.startRecording()

        // Monitor recorder state.
        self.recorderObserverTask?.cancel()
        self.recorderObserverTask = Task {
            await self.observeRecorderState()
        }
    }

    private func observeRecorderState() async {
        guard let recorder = audioRecorder else { return }

        // Continue observing until recording stops
        while self.isListening, recorder.isRecording {
            // Update transcript and error state from recorder
            if recorder.transcript != self.transcript {
                self.transcript = recorder.transcript
            }
            if let error = recorder.error {
                self.error = error
                self.isListening = false
                break
            }

            // Small delay to avoid tight loop
            do {
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            } catch {
                break
            }
        }
    }

    private func checkAuthorization() {
        // Check both speech recognition and microphone permissions
        let speechAuthStatus = SFSpeechRecognizer.authorizationStatus()
        let microphoneAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        self.isAvailable = speechAuthStatus == .authorized && microphoneAuthStatus == .authorized
    }

    // MARK: - Direct Audio Recording

    private func startDirectRecording() throws {
        // Create temporary file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "peekaboo_direct_recording_\(UUID().uuidString).wav"
        self.directAudioURL = tempDir.appendingPathComponent(fileName)

        guard let recordingURL = directAudioURL else {
            throw SpeechError.recordingFailed
        }

        // Configure audio settings for high-quality recording
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0, // 16kHz is standard for speech
            AVNumberOfChannelsKey: 1, // Mono
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]

        // Create and start recorder
        self.directAudioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
        self.directAudioRecorder?.prepareToRecord()
        self.directAudioRecorder?.record()

        // Update transcript to show recording status
        self.transcript = "[Recording audio for AI processing...]"
    }

    private func stopDirectRecording() {
        guard let recorder = directAudioRecorder else { return }

        // Stop recording
        recorder.stop()
        self.recordedAudioDuration = recorder.currentTime

        // Read the audio data
        if let url = directAudioURL,
           let data = try? Data(contentsOf: url)
        {
            self.recordedAudioData = data

            // Update transcript to show audio is ready
            let duration = Int(recordedAudioDuration ?? 0)
            self.transcript = "[Audio recorded: \(duration) seconds - ready to send to AI]"
        }

        // Clean up
        self.directAudioRecorder = nil
    }

    // MARK: - Tachikoma Audio Recognition

    private func startTachikomaRecognition() throws {
        // Create temporary file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "peekaboo_tachikoma_\(UUID().uuidString).wav"
        self.tachikomaAudioURL = tempDir.appendingPathComponent(fileName)

        guard let recordingURL = tachikomaAudioURL else {
            throw SpeechError.recordingFailed
        }

        // Configure audio settings for speech recognition optimized recording
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0, // 16kHz is optimal for speech recognition
            AVNumberOfChannelsKey: 1, // Mono
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]

        // Create and start recorder
        self.tachikomaAudioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
        self.tachikomaAudioRecorder?.prepareToRecord()
        self.tachikomaAudioRecorder?.record()

        // Create abort signal for potential cancellation
        self.tachikomaAbortSignal = AbortSignal()

        // Update transcript to show recording status
        self.transcript = "[Recording with Tachikoma Audio API...]"
    }

    private func stopTachikomaRecording() {
        guard let recorder = tachikomaAudioRecorder,
              let audioURL = tachikomaAudioURL else { return }

        // Stop recording
        recorder.stop()
        let duration = recorder.currentTime

        // Start transcription with Tachikoma
        Task {
            await self.transcribeWithTachikoma(audioURL: audioURL, duration: duration)
        }

        // Clean up recorder
        self.tachikomaAudioRecorder = nil
    }

    private func transcribeWithTachikoma(audioURL: URL, duration: TimeInterval) async {
        do {
            // Create AudioData from recorded file
            let audioData = try AudioData(contentsOf: audioURL)

            // Use Tachikoma's transcribe function with OpenAI Whisper
            let result = try await transcribe(
                audioData,
                using: .openai(.whisper1),
                language: "en",
                abortSignal: tachikomaAbortSignal)

            // Update transcript on main thread
            await MainActor.run {
                self.transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.recordedAudioData = audioData.data
                self.recordedAudioDuration = duration
            }

            // Clean up the temporary file
            try? FileManager.default.removeItem(at: audioURL)

        } catch {
            await MainActor.run {
                self.error = error
                self.transcript = "Error: \(error.localizedDescription)"
            }
        }

        // Clean up abort signal
        self.tachikomaAbortSignal = nil
        self.tachikomaAudioURL = nil
    }
}

// MARK: - Errors

enum SpeechError: LocalizedError {
    case notAuthorized
    case notInitialized
    case requestCreationFailed
    case recordingFailed
    case apiKeyRequired

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Microphone access is not authorized. Please enable it in System Settings."
        case .notInitialized:
            "Audio recorder not initialized."
        case .requestCreationFailed:
            "Failed to create audio recording request."
        case .recordingFailed:
            "Failed to start audio recording."
        case .apiKeyRequired:
            "OpenAI API key required for Whisper transcription."
        }
    }
}

// MARK: - SFSpeechRecognizerDelegate

extension SpeechRecognizer {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        // Update availability when speech recognizer availability changes
        Task { @MainActor in
            self.checkAuthorization()
        }
    }
}
