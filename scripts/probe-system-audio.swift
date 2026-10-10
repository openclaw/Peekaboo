// Standalone feasibility probe. Compile with swiftc -swift-version 6 -parse-as-library.
// This does not install or alter Peekaboo's production Bridge.
import AVFoundation
import CoreAudio
import Darwin
import Foundation

enum ProbeError: LocalizedError {
    case invalid(String)
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        case let .coreAudio(operation, status): "\(operation) failed: OSStatus \(status)"
        }
    }
}

struct CaptureRequest {
    let pid: Int32?
    let seconds: Double
    let output: URL

    init(arguments: [String]) throws {
        guard arguments.count == 3 else {
            throw ProbeError.invalid("Usage: probe-system-audio <system|PID> <seconds: 0.1...60> <new-output.caf>")
        }
        if arguments[0] == "system" {
            self.pid = nil
        } else {
            guard let pid = Int32(arguments[0]), pid > 0 else {
                throw ProbeError.invalid("PID must be a positive Int32; use system for all output.")
            }
            self.pid = pid
        }
        guard let seconds = Double(arguments[1]), seconds.isFinite, (0.1...60).contains(seconds) else {
            throw ProbeError.invalid("Duration must be finite and between 0.1 and 60 seconds.")
        }
        self.seconds = seconds
        self.output = URL(fileURLWithPath: NSString(string: arguments[2]).expandingTildeInPath)
        guard self.output.pathExtension.lowercased() == "caf" else {
            throw ProbeError.invalid("Output must use .caf (lossless native PCM).")
        }
        guard !FileManager.default.fileExists(atPath: self.output.path) else {
            throw ProbeError.invalid("Output already exists; capture never overwrites a file.")
        }
    }
}

struct CaptureEvidence: Codable {
    let pid: Int32?
    let path: String
    let frames: Int64
    let samples: Int64
    let sampleRate: Double
    let channels: UInt32
    let peak: Double
    let rms: Double
    let nonzeroSamples: Int64
    let warning: String?
}

/// All mutable state is confined to the IOProc's serial queue. Read/close only
/// after AudioDeviceStop and queue.sync; Core Audio never receives this object elsewhere.
final class PCMSink: @unchecked Sendable {
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private(set) var error: (any Error)?
    private(set) var frames: Int64 = 0
    private(set) var samples: Int64 = 0
    private(set) var nonzeroSamples: Int64 = 0
    private(set) var peak: Double = 0
    private var sumSquares: Double = 0

    init(url: URL, format: AVAudioFormat) throws {
        self.format = format
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        self.file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    func consume(_ input: UnsafePointer<AudioBufferList>) {
        guard self.error == nil else { return }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: self.format, bufferListNoCopy: input, deallocator: nil) else {
            self.error = ProbeError.invalid("Core Audio supplied an incompatible PCM buffer.")
            return
        }
        do {
            try self.file?.write(from: pcm)
            self.frames += Int64(pcm.frameLength)
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let values = UnsafeBufferPointer(
                    start: data.assumingMemoryBound(to: Float.self),
                    count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                for sample in values {
                    let value = Double(sample)
                    guard value.isFinite else {
                        throw ProbeError.invalid("Core Audio supplied non-finite samples.")
                    }
                    self.samples += 1
                    if sample != 0 {
                        self.nonzeroSamples += 1
                    }
                    self.peak = max(self.peak, abs(value))
                    self.sumSquares += value * value
                }
            }
        } catch {
            self.error = error
        }
    }

    var rms: Double {
        self.samples == 0 ? 0 : sqrt(self.sumSquares / Double(self.samples))
    }

    func close() {
        self.file = nil
    }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw ProbeError.coreAudio(operation, status) }
}

func validateOutputInputStreams(_ bytes: UInt32) throws {
    guard bytes == 0 else {
        throw ProbeError
            .invalid("The output device has physical input streams; this probe supports output-only devices.")
    }
}

func terminateWithMessage(_ message: String, status: Int32) -> Never {
    // A disconnected reader must not replace our exit status with SIGPIPE.
    _ = signal(SIGPIPE, SIG_IGN)
    // A full stderr pipe must not keep a stalled HAL process alive.
    let flags = fcntl(STDERR_FILENO, F_GETFL)
    if flags >= 0, fcntl(STDERR_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 {
        message.withCString { pointer in
            _ = write(STDERR_FILENO, pointer, strlen(pointer))
        }
    }
    _exit(status)
}

func terminateAtDeadline() -> Never {
    terminateWithMessage(
        "Core Audio exceeded the recording deadline; no live audio result was verified. "
            + "A private .peekaboo-audio-* partial directory may remain beside the output.\n",
        status: 2)
}

func makeDeadlineWorkItem() -> DispatchWorkItem {
    DispatchWorkItem { @Sendable in
        terminateAtDeadline()
    }
}

@available(macOS 14.2, *)
func record(_ request: CaptureRequest) async throws -> CaptureEvidence {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let description: CATapDescription
    if var pid = request.pid {
        var process: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<Int32>.size),
            &pid,
            &size,
            &process), "resolve PID")
        guard process != kAudioObjectUnknown else {
            throw ProbeError.invalid("No Core Audio process exists for PID \(pid).")
        }
        description = CATapDescription(stereoMixdownOfProcesses: [process])
    } else {
        description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    }
    description.name = "Peekaboo system audio prototype"
    description.muteBehavior = .unmuted
    description.isPrivate = true
    var tap: AudioObjectID = 0
    try check(AudioHardwareCreateProcessTap(description, &tap), "create tap")
    defer { AudioHardwareDestroyProcessTap(tap) }
    address.mSelector = kAudioTapPropertyFormat
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "read tap format")
    guard asbd.mFormatID == kAudioFormatLinearPCM,
          asbd.mBitsPerChannel == 32,
          asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
          asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
          asbd.mChannelsPerFrame > 0,
          asbd.mChannelsPerFrame <= 2,
          let format = AVAudioFormat(streamDescription: &asbd)
    else { throw ProbeError.invalid("Tap did not provide supported float32 mono/stereo PCM.") }

    // Clock the private aggregate from the current output. Never make it default.
    address.mSelector = kAudioHardwarePropertyDefaultOutputDevice
    var clock: AudioObjectID = 0
    size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &clock), "read output clock")
    address.mSelector = kAudioDevicePropertyDeviceUID
    var rawUID: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(clock, &address, 0, nil, &size, &rawUID), "read output UID")
    guard let rawUID else { throw ProbeError.invalid("No default output clock.") }
    let clockUID = rawUID.takeRetainedValue()
    // Aggregates include every input stream of their real subdevices. A duplex
    // headset/interface would add microphone/line input before the tap buffers.
    // Refuse it rather than interpreting hardware input as selected-process audio.
    address.mSelector = kAudioDevicePropertyStreams
    address.mScope = kAudioDevicePropertyScopeInput
    var inputStreamBytes: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(clock, &address, 0, nil, &inputStreamBytes), "inspect output inputs")
    try validateOutputInputStreams(inputStreamBytes)
    let settings: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Peekaboo audio prototype",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceMainSubDeviceKey: clockUID,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [[
            kAudioSubTapUIDKey: description.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true,
        ]],
    ]
    var device: AudioObjectID = 0
    try check(AudioHardwareCreateAggregateDevice(settings as CFDictionary, &device), "create aggregate")
    defer { AudioHardwareDestroyAggregateDevice(device) }

    let staging = request.output.deletingLastPathComponent().appendingPathComponent(
        ".peekaboo-audio-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: staging,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    let temporary = staging.appendingPathComponent("capture.caf")
    let sink = try PCMSink(url: temporary, format: format)
    let queue = DispatchQueue(label: "boo.peekaboo.audio-prototype")
    var callback: AudioDeviceIOProcID?
    try check(AudioDeviceCreateIOProcIDWithBlock(&callback, device, queue) { _, input, _, _, _ in
        sink.consume(input)
    }, "create IOProc")
    defer {
        if let callback {
            AudioDeviceDestroyIOProcID(device, callback)
        }
        queue.sync { sink.close() }
    }
    try check(AudioDeviceStart(device, callback), "start recording")
    var stopped = false
    defer {
        if !stopped {
            AudioDeviceStop(device, callback)
        }
    }
    try await Task.sleep(for: .seconds(request.seconds))
    try check(AudioDeviceStop(device, callback), "stop recording")
    stopped = true
    return try queue.sync {
        sink.close()
        if let error = sink.error {
            throw error
        }
        guard sink.frames > 0 else {
            throw ProbeError.invalid("No audio frames; check system-audio permission and the selected output.")
        }
        // moveItem refuses a concurrent existing destination too.
        try FileManager.default.moveItem(at: temporary, to: request.output)
        return CaptureEvidence(
            pid: request.pid,
            path: request.output.path,
            frames: sink.frames,
            samples: sink.samples,
            sampleRate: asbd.mSampleRate,
            channels: asbd.mChannelsPerFrame,
            peak: sink.peak,
            rms: sink.rms,
            nonzeroSamples: sink.nonzeroSamples,
            warning: sink.nonzeroSamples == 0
                ? "All samples are zero: silence or denied capture; permission and audible playback are unverified."
                : nil)
    }
}

@main
struct SystemAudioProbe {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--self-test-deadline"] {
                terminateAtDeadline()
            }
            if arguments == ["--self-test-scheduled-deadline"] {
                let deadline = makeDeadlineWorkItem()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05, execute: deadline)
                try await Task.sleep(for: .seconds(2))
                throw ProbeError.invalid("Scheduled deadline did not terminate the process")
            }
            if arguments == ["--self-test"] {
                try runSelfTests()
                return
            }
            let request = try CaptureRequest(arguments: arguments)
            guard #available(macOS 14.2, *) else {
                throw ProbeError.invalid("Core Audio taps require macOS 14.2 or later.")
            }
            // Native HAL calls can block even after a successful start. The probe
            // is an isolated process; never use process exit as a GUI-host timeout.
            let deadline = makeDeadlineWorkItem()
            DispatchQueue.global().asyncAfter(deadline: .now() + request.seconds + 10, execute: deadline)
            defer { deadline.cancel() }
            let evidence = try await record(request)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let json = try String(data: encoder.encode(evidence), encoding: .utf8) else {
                throw ProbeError.invalid("Cannot encode capture evidence as UTF-8")
            }
            print(json)
        } catch {
            terminateWithMessage("\(error.localizedDescription)\n", status: 1)
        }
    }
}
