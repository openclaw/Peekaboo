import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

struct SeeRequest {
    let appTarget: String?
    let windowIDValue: Value?
    let path: String?
    let snapshotId: String?
    let annotate: Bool
    let ocr: Bool
    let webFocus: Bool
    let traversalBudget: AXTraversalBudget
    let roi: CaptureRegionOfInterest?

    init(arguments: ToolArguments) throws {
        self.appTarget = arguments.getString("app_target")
        self.windowIDValue = arguments.getValue(for: "window_id")
        self.path = arguments.getString("path")
        self.snapshotId = arguments.getString("snapshot")
        self.annotate = arguments.getBool("annotate") ?? false
        self.ocr = arguments.getBool("ocr") ?? false
        self.webFocus = arguments.getBool("web_focus") ?? false
        if let rawROI = arguments.getString("roi")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawROI.isEmpty
        {
            guard self.windowIDValue != nil else {
                throw PeekabooError.invalidInput("roi requires an exact window_id")
            }
            guard self.snapshotId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                throw PeekabooError.invalidInput("roi requires a fresh snapshot; omit snapshot")
            }
            self.roi = try CaptureRegionOfInterest.parse(rawROI)
        } else {
            self.roi = nil
        }
        self.traversalBudget = AXTraversalBudget.resolved(
            maxDepth: Self.positiveInt("max_depth", in: arguments),
            maxElementCount: Self.positiveInt("max_elements", in: arguments),
            maxChildrenPerNode: Self.positiveInt("max_children", in: arguments))
    }

    private static func positiveInt(_ key: String, in arguments: ToolArguments) -> Int? {
        guard let value = arguments.getInt(key), value > 0 else {
            return nil
        }
        return value
    }
}

struct ScreenshotOutput {
    let screenshotPath: String
    let annotatedPath: String?
    let imageData: Data
}

struct SeeCaptureArtifact {
    let observationPath: String
    let rawOutputPath: String
    let annotatedOutputPath: String
    private let cleanupDirectory: URL?

    init(requestedPath: String?) throws {
        let hasExplicitPath = requestedPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let defaultFileName = "peekaboo-observation-\(UUID().uuidString).png"
        let rawOutputURL = ObservationOutputPathResolver.resolve(
            path: hasExplicitPath ? requestedPath : nil,
            format: .png,
            defaultFileName: defaultFileName)

        self.rawOutputPath = rawOutputURL.path
        self.annotatedOutputPath = ObservationOutputWriter.annotatedScreenshotPath(
            forRawScreenshotPath: rawOutputURL.path)

        if hasExplicitPath {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("peekaboo-see-response-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            self.observationPath = directory.appendingPathComponent("capture.png").path
            self.cleanupDirectory = directory
        } else {
            self.observationPath = rawOutputURL.path
            self.cleanupDirectory = nil
        }
    }

    func publish(rawData: Data, annotatedData: Data?) throws -> (rawPath: String, annotatedPath: String?) {
        if self.cleanupDirectory != nil {
            let rawURL = URL(fileURLWithPath: self.rawOutputPath)
            try FileManager.default.createDirectory(
                at: rawURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try rawData.write(to: rawURL, options: .atomic)
            if let annotatedData {
                try annotatedData.write(
                    to: URL(fileURLWithPath: self.annotatedOutputPath),
                    options: .atomic)
            }
        }
        return (self.rawOutputPath, annotatedData == nil ? nil : self.annotatedOutputPath)
    }

    func cleanup() {
        guard let cleanupDirectory else { return }
        try? FileManager.default.removeItem(at: cleanupDirectory)
    }

    var observationAnnotatedPath: String {
        ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: self.observationPath)
    }
}

@MainActor
struct SeeSummaryBuilder {
    let snapshot: UISnapshot
    let elements: [UIElement]
    let screenshotPath: String
    let truncationInfo: DetectionTruncationInfo?
    let traversalBudget: AXTraversalBudget?

    func build() async -> String {
        var lines = self.headerLines()
        await lines.append(contentsOf: self.metadataLines())
        lines.append("Screenshot: \(self.screenshotPath)")
        lines.append("Elements found: \(self.elements.count)")
        lines.append(contentsOf: self.truncationWarningLines())
        lines.append("")
        lines.append(contentsOf: self.elementSection())
        lines.append("")
        lines.append("Use opaque element IDs for interaction only when the element is marked actionable.")
        return lines.joined(separator: "\n")
    }

    private func headerLines() -> [String] {
        [
            "📸 UI State Captured",
            "Snapshot ID: \(self.snapshot.id)",
        ]
    }

    private func metadataLines() async -> [String] {
        guard let metadata = await self.snapshot.screenshotMetadata else { return [] }
        var lines: [String] = []
        if let appInfo = metadata.applicationInfo {
            lines.append("Application: \(appInfo.name)")
        }
        if let windowInfo = metadata.windowInfo {
            lines.append("Window: \(windowInfo.title)")
        }
        return lines
    }

    private func elementSection() -> [String] {
        let elementsByRole = Dictionary(grouping: self.elements, by: { $0.role })
        var lines = ["UI Elements:"]
        for (role, roleElements) in elementsByRole.sorted(by: { $0.key < $1.key }) {
            lines.append("")
            lines.append(self.roleHeader(role: role, elements: roleElements))
            lines.append(contentsOf: roleElements.map(self.describeElement))
        }
        return lines
    }

    private func roleHeader(role: String, elements: [UIElement]) -> String {
        let actionableCount = elements.count(where: { $0.isActionable })
        return "\(role) (\(elements.count) found, \(actionableCount) actionable):"
    }

    private func truncationWarningLines() -> [String] {
        guard let truncationInfo, truncationInfo.isTruncated else { return [] }
        return ["", truncationInfo.automationToolRemediationMessage(budget: self.traversalBudget)]
    }

    private func describeElement(_ element: UIElement) -> String {
        SeeElementTextFormatter.describe(element)
    }
}
