import AVFoundation
import Darwin
import Foundation

func runSelfTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("result.caf")
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeError.invalid("Self-test failed: \(message)") }
    }
    var rejected = 0
    for arguments in [
        [], ["system", "nan", output.path], ["system", "inf", output.path],
        ["system", "0", output.path], ["system", "61", output.path],
        ["0", "1", output.path], ["-1", "1", output.path],
        ["2147483648", "1", output.path], ["system", "1", "invalid.wav"],
    ] {
        do { _ = try CaptureRequest(arguments: arguments) } catch { rejected += 1 }
    }
    try require(rejected == 9, "invalid requests must fail before Core Audio is touched")
    let request = try CaptureRequest(arguments: ["123", "0.5", output.path])
    try require(request.pid == 123 && request.seconds == 0.5, "PID selection")
    let system = try CaptureRequest(arguments: ["system", "1", output.path])
    try require(system.pid == nil, "explicit system selection")
    try validateOutputInputStreams(0)
    var duplexRejected = false
    do { try validateOutputInputStreams(4) } catch { duplexRejected = true }
    try require(duplexRejected, "physical input streams must be rejected")
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64),
          let channels = buffer.floatChannelData
    else { throw ProbeError.invalid("Cannot allocate fixture PCM") }
    buffer.frameLength = 64
    for channel in 0..<2 {
        for frame in 0..<64 {
            channels[channel][frame] = frame % 2 == 0 ? 0.5 : -0.5
        }
    }
    let sink = try PCMSink(url: output, format: format)
    sink.consume(buffer.audioBufferList)
    sink.close()
    try require(sink.error == nil, "PCM write")
    try require(sink.frames == 64 && sink.samples == 128, "stereo frame and sample counts")
    try require(sink.peak == 0.5 && sink.rms == 0.5 && sink.nonzeroSamples == 128, "signal statistics")
    let recorded = try AVAudioFile(forReading: output)
    try require(recorded.length == 64, "CAF remains readable after closing")
    guard let decoded = AVAudioPCMBuffer(pcmFormat: recorded.processingFormat, frameCapacity: 64) else {
        throw ProbeError.invalid("Cannot allocate decoded PCM")
    }
    try recorded.read(into: decoded)
    try require(decoded.frameLength == 64, "decoded frame count")
    guard let decodedChannels = decoded.floatChannelData else {
        throw ProbeError.invalid("Missing decoded float channels")
    }
    for channel in 0..<2 {
        for frame in 0..<64 {
            try require(decodedChannels[channel][frame] == channels[channel][frame], "decoded sample identity")
        }
    }
    var overwriteRejected = false
    do { _ = try CaptureRequest(arguments: ["system", "1", output.path]) } catch { overwriteRejected = true }
    try require(overwriteRejected, "existing output must not be overwritten")
    let silent = try PCMSink(url: root.appendingPathComponent("silent.caf"), format: format)
    for channel in 0..<2 {
        for frame in 0..<64 {
            channels[channel][frame] = 0
        }
    }
    silent.consume(buffer.audioBufferList)
    silent.close()
    try require(silent.samples == 128 && silent.peak == 0 && silent.rms == 0, "silence still has frames")
    try require(silent.nonzeroSamples == 0, "silent buffers do not establish permission or playback")
    try testTerminationWithFullPipe(arguments: ["--self-test-deadline"], expectedStatus: 2)
    try testTerminationWithFullPipe(arguments: ["system", "nan", "fixture.caf"], expectedStatus: 1)
    try testTerminationWithFullPipe(arguments: ["--self-test-deadline"], expectedStatus: 2, closedReader: true)
    try testTerminationWithFullPipe(arguments: ["--self-test-scheduled-deadline"], expectedStatus: 2)
    try testTerminationWithFullPipe(
        arguments: ["--self-test-scheduled-deadline"],
        expectedStatus: 2,
        closedReader: true)
    try testTerminationWithFullPipe(arguments: ["system", "nan", "fixture.caf"], expectedStatus: 1, closedReader: true)
    print(
        "PASS: request/source checks, PCM round-trip/statistics, overwrite guard, silence, full/closed-pipe exits")
}

func testTerminationWithFullPipe(arguments: [String], expectedStatus: Int32, closedReader: Bool = false) throws {
    let pipe = Pipe()
    let writer = pipe.fileHandleForWriting.fileDescriptor
    let flags = fcntl(writer, F_GETFL)
    guard flags >= 0, fcntl(writer, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw ProbeError.invalid("Cannot configure deadline fixture pipe")
    }
    let bytes = [UInt8](repeating: 1, count: 4096)
    try bytes.withUnsafeBytes { buffer in
        while true {
            let count = write(writer, buffer.baseAddress, buffer.count)
            if count >= 0 {
                continue
            }
            guard errno == EAGAIN else { throw ProbeError.invalid("Cannot fill deadline fixture pipe") }
            break
        }
    }
    guard fcntl(writer, F_SETFL, flags) == 0 else { throw ProbeError.invalid("Cannot restore fixture blocking mode") }
    if closedReader {
        try pipe.fileHandleForReading.close()
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = arguments
    child.standardError = pipe
    try child.run()
    let expiry = Date().addingTimeInterval(5)
    while child.isRunning, Date() < expiry {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if child.isRunning {
        _ = kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        throw ProbeError.invalid("Deadline blocked on a full stderr pipe")
    }
    child.waitUntilExit()
    guard child.terminationReason == .exit, child.terminationStatus == expectedStatus else {
        throw ProbeError.invalid("Full-pipe fixture did not exit with expected status")
    }
}
