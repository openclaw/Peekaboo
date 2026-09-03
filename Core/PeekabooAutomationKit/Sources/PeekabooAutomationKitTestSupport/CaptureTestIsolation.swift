import Foundation
@_spi(Testing) import PeekabooAutomationKit
import Testing

/// Synthetic capture tests use private locks and refuse any uninjected ownership claim.
public struct CaptureTestIsolation: TestTrait, SuiteTrait, TestScoping {
    public typealias TestBody = @concurrent @Sendable () async throws -> Void

    public init() {}

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: TestBody) async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ScreenCaptureService.withIsolatedCaptureCoordination(directory: directory) {
            try await function()
        }
    }
}
