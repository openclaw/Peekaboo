import Foundation
import Testing
@testable import Peekaboo

@MainActor
struct SpeechRecognizerTests {
    @Test
    func `stopping whisper cancels and releases recorder observer`() async throws {
        let recorder = RecordingSpeechAudioRecorder()
        let recognizer = SpeechRecognizer(settings: PeekabooSettings(), audioRecorder: recorder)
        recognizer.isAvailable = true
        recognizer.recognitionMode = .whisper

        try recognizer.startListening()
        #expect(recognizer.hasRecorderObserverTask)

        for _ in 0..<20 where recorder.pollCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.pollCount > 0)

        recognizer.stopListening()
        let pollsAfterStop = recorder.pollCount

        #expect(!recognizer.hasRecorderObserverTask)
        #expect(!recognizer.isListening)
        #expect(recorder.stopCount == 1)

        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.pollCount == pollsAfterStop)
    }

    @Test
    func `stopping after recorder error still releases observer`() async throws {
        let recorder = RecordingSpeechAudioRecorder(error: SpeechRecorderTestError.failed)
        let recognizer = SpeechRecognizer(settings: PeekabooSettings(), audioRecorder: recorder)
        recognizer.isAvailable = true
        recognizer.recognitionMode = .whisper

        try recognizer.startListening()
        for _ in 0..<20 where recognizer.isListening {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!recognizer.isListening)
        #expect(recognizer.hasRecorderObserverTask)

        recognizer.stopListening()

        #expect(!recognizer.hasRecorderObserverTask)
        #expect(recorder.stopCount == 1)
    }
}

private enum SpeechRecorderTestError: Error {
    case failed
}

@MainActor
private final class RecordingSpeechAudioRecorder: SpeechAudioRecording {
    private var recording = false
    var isRecording: Bool {
        self.pollCount += 1
        return self.recording
    }

    var transcript = ""
    let error: (any Error)?
    private(set) var pollCount = 0
    private(set) var stopCount = 0

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func startRecording() throws {
        self.recording = true
    }

    func stopRecording() {
        self.stopCount += 1
        self.recording = false
    }
}
