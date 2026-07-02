import AVFoundation
import SwiftUI
import Tachikoma

/// Voice input interface for controlling agents with speech
struct SpeechInputView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var speechRecognizer: SpeechRecognizer
    @State private var isRecordingPermissionGranted = false
    @State private var showingPermissionAlert = false

    // Agent integration
    let agent: PeekabooAgent
    let onTranscriptReceived: (String) -> Void
    let onAudioReceived: (Data, TimeInterval) -> Void

    // UI state
    @State private var recordingProgress: Double = 0.0
    @State private var recordingTimer: Timer?
    @State private var recordingStartTime: Date?

    init(
        settings: PeekabooSettings,
        agent: PeekabooAgent,
        onTranscriptReceived: @escaping (String) -> Void = { _ in },
        onAudioReceived: @escaping (Data, TimeInterval) -> Void = { _, _ in })
    {
        self.agent = agent
        self.onTranscriptReceived = onTranscriptReceived
        self.onAudioReceived = onAudioReceived
        self._speechRecognizer = State(initialValue: SpeechRecognizer(settings: settings))
    }

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text("Voice Control")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Speak to control your agent")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Recognition mode selector
            Picker("Recognition Mode", selection: self.$speechRecognizer.recognitionMode) {
                ForEach(RecognitionMode.allCases, id: \.self) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.rawValue)
                            .font(.headline)
                        Text(mode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(self.speechRecognizer.isListening)

            // Recording visualization
            ZStack {
                // Background circle
                Circle()
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 200, height: 200)

                // Progress ring
                if self.speechRecognizer.isListening {
                    Circle()
                        .trim(from: 0, to: self.recordingProgress)
                        .stroke(
                            AngularGradient(
                                colors: [.blue, .green, .blue],
                                center: .center,
                                startAngle: .degrees(-90),
                                endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 190, height: 190)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.1), value: self.recordingProgress)
                }

                // Microphone icon
                VStack(spacing: 8) {
                    Image(systemName: self.speechRecognizer.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundColor(self.speechRecognizer.isListening ? .red : .primary)
                        .scaleEffect(self.speechRecognizer.isListening ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: self.speechRecognizer.isListening)

                    Text(self.speechRecognizer.isListening ? "Listening..." : "Tap to start")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onTapGesture {
                Task {
                    await self.toggleRecording()
                }
            }

            // Transcript display
            if !self.speechRecognizer.transcript.isEmpty {
                ScrollView {
                    Text(self.speechRecognizer.transcript)
                        .font(.body)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)
                }
                .frame(maxHeight: 120)
            }

            // Error display
            if let error = speechRecognizer.error {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
            }

            // Action buttons
            HStack(spacing: 16) {
                // Cancel button
                Button("Cancel") {
                    self.stopRecording()
                    self.dismiss()
                }
                .buttonStyle(.bordered)

                // Send to agent button
                Button("Send to Agent") {
                    self.sendToAgent()
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.speechRecognizer.transcript.isEmpty || self.agent.isProcessing)

                // Stop/Start recording button
                Button(self.speechRecognizer.isListening ? "Stop" : "Record") {
                    Task {
                        await self.toggleRecording()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!self.isRecordingPermissionGranted)
            }
        }
        .padding(24)
        .frame(width: 480, height: 560)
        .onAppear {
            self.checkPermissions()
        }
        .alert("Recording Permission Required", isPresented: self.$showingPermissionAlert) {
            Button("Open Settings") {
                if let settingsURL =
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                {
                    NSWorkspace.shared.open(settingsURL)
                }
            }
            Button("Cancel", role: .cancel) {
                self.dismiss()
            }
        } message: {
            Text("Peekaboo needs microphone access to use voice control. Please enable it in System Settings.")
        }
    }

    // MARK: - Private Methods

    private func checkPermissions() {
        Task {
            let authorized = await speechRecognizer.requestAuthorization()
            await MainActor.run {
                self.isRecordingPermissionGranted = authorized
                if !authorized {
                    self.showingPermissionAlert = true
                }
            }
        }
    }

    private func toggleRecording() async {
        if self.speechRecognizer.isListening {
            self.stopRecording()
        } else {
            await self.startRecording()
        }
    }

    private func startRecording() async {
        guard self.isRecordingPermissionGranted else {
            self.showingPermissionAlert = true
            return
        }

        do {
            try self.speechRecognizer.startListening()
            self.recordingStartTime = Date()
            self.startRecordingTimer()
        } catch {
            self.speechRecognizer.error = error
        }
    }

    private func stopRecording() {
        self.speechRecognizer.stopListening()
        self.stopRecordingTimer()

        // If we have recorded audio data (from direct mode), pass it to the callback
        if let audioData = speechRecognizer.recordedAudioData,
           let duration = speechRecognizer.recordedAudioDuration
        {
            self.onAudioReceived(audioData, duration)
        }

        // Always pass transcript if available
        if !self.speechRecognizer.transcript.isEmpty {
            self.onTranscriptReceived(self.speechRecognizer.transcript)
        }
    }

    private func sendToAgent() {
        guard !self.speechRecognizer.transcript.isEmpty else { return }

        let transcript = self.speechRecognizer.transcript

        // Stop recording and cancel the observer task before dismissing,
        // otherwise the poll loop keeps running after the view is gone.
        self.stopRecording()
        self.dismiss()

        // Send to agent based on recognition mode
        Task {
            do {
                if self.speechRecognizer.recognitionMode == .direct,
                   let audioData = speechRecognizer.recordedAudioData,
                   let duration = speechRecognizer.recordedAudioDuration
                {
                    // Send raw audio to agent
                    try await self.agent.executeTaskWithAudio(
                        audioData: audioData,
                        duration: duration,
                        transcript: transcript)
                } else {
                    // Send transcribed text to agent
                    try await self.agent.executeTask(transcript)
                }
            } catch {
                // Handle error - could show an alert or update UI state
                print("Failed to execute agent task: \\(error)")
            }
        }
    }

    private func startRecordingTimer() {
        self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard let startTime = recordingStartTime else { return }
                let elapsed = Date().timeIntervalSince(startTime)

                // Update progress (max 30 seconds for visual purposes)
                self.recordingProgress = min(elapsed / 30.0, 1.0)
            }
        }
    }

    private func stopRecordingTimer() {
        self.recordingTimer?.invalidate()
        self.recordingTimer = nil
        self.recordingProgress = 0.0
        self.recordingStartTime = nil
    }
}

// MARK: - Preview

#Preview {
    SpeechInputView(
        settings: PeekabooSettings(),
        agent: PeekabooAgent(
            settings: PeekabooSettings(),
            sessionStore: SessionStore()))
}
