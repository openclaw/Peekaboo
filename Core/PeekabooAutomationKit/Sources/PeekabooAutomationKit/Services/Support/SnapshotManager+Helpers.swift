import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation

struct SnapshotImplicitLatestPreservation: Codable {
    let snapshotId: String
    let invalidatedThrough: Date
    let preservedAt: Date
}

private struct SnapshotLatestCandidate {
    let url: URL
    let createdAt: Date
}

private struct SnapshotLatestReadState {
    let cutoff: Date
    let candidates: [SnapshotLatestCandidate]
    let preservation: SnapshotImplicitLatestPreservation?
}

private enum SnapshotStateLockMode {
    case read
    case write

    var operation: Int32 {
        switch self {
        case .read: LOCK_SH
        case .write: LOCK_EX
        }
    }
}

extension SnapshotManager {
    // MARK: - Helpers

    private static let pendingSnapshotMarkerName = ".pending"
    private static let snapshotObservationStartName = ".observation-start"

    static func latestWatermark(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    func makeSnapshotID() -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let randomSuffix = Int.random(in: 1000...9999)
        return "\(timestamp)-\(randomSuffix)"
    }

    func getSnapshotStorageURL() -> URL {
        let url = self.snapshotStorageURLOverride ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".peekaboo/snapshots")

        // Ensure the directory exists
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        return url
    }

    func getSnapshotPath(for snapshotId: String) -> URL {
        self.getSnapshotStorageURL().appendingPathComponent(snapshotId)
    }

    func markSnapshotPending(at snapshotURL: URL, observationStartedAt: Date) throws {
        let startedAtData = try JSONEncoder().encode(observationStartedAt)
        try startedAtData.write(
            to: snapshotURL.appendingPathComponent(Self.snapshotObservationStartName),
            options: .atomic)
        try Data().write(
            to: snapshotURL.appendingPathComponent(Self.pendingSnapshotMarkerName),
            options: .atomic)
    }

    func isPendingSnapshot(at snapshotURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: snapshotURL.appendingPathComponent(Self.pendingSnapshotMarkerName).path)
    }

    func snapshotCreationDate(at snapshotURL: URL, fallback: Date? = nil) -> Date? {
        let observationStartURL = snapshotURL.appendingPathComponent(Self.snapshotObservationStartName)
        if let data = try? Data(contentsOf: observationStartURL),
           let date = try? JSONDecoder().decode(Date.self, from: data)
        {
            return date
        }
        if let fallback {
            return fallback
        }
        return try? snapshotURL.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    func snapshotDirectoryURLs(
        includingPending: Bool,
        requiringSnapshotData: Bool = true) throws -> [URL]
    {
        do {
            return try self.withImplicitLatestInvalidationLock(mode: .read) {
                self.snapshotDirectoryURLsUnlocked(
                    includingPending: includingPending,
                    requiringSnapshotData: requiringSnapshotData)
            }
        } catch {
            self.logger.error("Failed to lock snapshot state for directory read: \(error)")
            // Do not return []: lock failure is not "no snapshots exist".
            throw SnapshotError.storageError(
                "Failed to lock snapshot state for directory read: \(error.localizedDescription)")
        }
    }

    private func snapshotDirectoryURLsUnlocked(
        includingPending: Bool,
        requiringSnapshotData: Bool = true) -> [URL]
    {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: self.getSnapshotStorageURL(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: includingPending ? [] : .skipsHiddenFiles)
        else { return [] }
        return urls.filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            if url.lastPathComponent.hasPrefix(".pending-") {
                return includingPending
            }
            guard includingPending || !self.isPendingSnapshot(at: url) else { return false }
            return !requiringSnapshotData || FileManager.default.fileExists(
                atPath: url.appendingPathComponent("snapshot.json").path)
        }
    }

    private var implicitLatestInvalidationWatermarkURL: URL {
        self.getSnapshotStorageURL().appendingPathComponent(".implicit-latest-invalidated-at")
    }

    private var implicitLatestInvalidationLockURL: URL {
        self.getSnapshotStorageURL().appendingPathComponent(".implicit-latest-invalidation.lock")
    }

    private var implicitLatestPreservationURL: URL {
        self.getSnapshotStorageURL().appendingPathComponent(".implicit-latest-preserved-snapshot")
    }

    func implicitLatestInvalidationWatermark() -> Date? {
        do {
            return try self.withImplicitLatestInvalidationLock(mode: .read) {
                self.readImplicitLatestInvalidationWatermarkUnlocked()
            }
        } catch {
            // A transient lock failure must not be treated as "invalidate everything": the file is
            // written atomically, so an unlocked read is a safe best effort.
            self.logger.error(
                "Failed to lock implicit-latest watermark for reading; falling back to unlocked read: \(error)")
            return self.readImplicitLatestInvalidationWatermarkUnlocked()
        }
    }

    private func readImplicitLatestInvalidationWatermarkUnlocked() -> Date? {
        let url = self.implicitLatestInvalidationWatermarkURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let watermark = try? JSONDecoder().decode(Date.self, from: data)
        else {
            // A corrupt watermark still marks a real past invalidation, so approximate it with the
            // file's own timestamps. If even those are unreadable, fail open: hiding every cached
            // snapshot over a transient I/O hiccup is worse than one potentially stale lookup.
            self.logger.error(
                "Implicit-latest invalidation watermark is unreadable; using its file timestamp instead")
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            return values?.contentModificationDate ?? values?.creationDate
        }
        return watermark
    }

    func writeImplicitLatestInvalidationWatermark(_ date: Date) throws {
        try self.writeImplicitLatestInvalidationState(through: date, preserving: nil, preservedAt: nil)
    }

    func writeImplicitLatestInvalidationState(
        through cutoff: Date,
        preserving snapshotId: String?,
        preservedAt: Date?) throws
    {
        let sharedWatermark = try self.desktopMutationWatermarkStore?.advance(through: cutoff)
        try self.withImplicitLatestInvalidationLock(mode: .write) {
            let existing = self.readImplicitLatestInvalidationWatermarkUnlocked()
            let preservation = self.readImplicitLatestPreservationUnlocked()
            let watermark = max(Self.latestWatermark(existing, sharedWatermark) ?? cutoff, cutoff)
            let data = try JSONEncoder().encode(watermark)
            try data.write(to: self.implicitLatestInvalidationWatermarkURL, options: .atomic)

            if let snapshotId,
               let snapshotURL = self.safeSnapshotURL(for: snapshotId)
            {
                let pendingURL = snapshotURL.appendingPathComponent(Self.pendingSnapshotMarkerName)
                if FileManager.default.fileExists(atPath: pendingURL.path) {
                    try FileManager.default.removeItem(at: pendingURL)
                }
            }

            if let snapshotId,
               let preservedAt,
               self.validPreservationSnapshotURL(for: snapshotId) != nil,
               watermark <= cutoff
            {
                let next = SnapshotImplicitLatestPreservation(
                    snapshotId: snapshotId,
                    invalidatedThrough: cutoff,
                    preservedAt: preservedAt)
                try JSONEncoder().encode(next).write(to: self.implicitLatestPreservationURL, options: .atomic)
            } else if let preservation, watermark > preservation.invalidatedThrough {
                try? FileManager.default.removeItem(at: self.implicitLatestPreservationURL)
            }
        }
    }

    func implicitLatestPreservation() -> SnapshotImplicitLatestPreservation? {
        do {
            return try self.withImplicitLatestInvalidationLock(mode: .read) {
                let watermark = self.readImplicitLatestInvalidationWatermarkUnlocked()
                return self.validImplicitLatestPreservationUnlocked(watermark: watermark)
            }
        } catch {
            // Same fail-open rationale as the watermark reader: preservation records are written
            // atomically, so an unlocked read beats silently dropping a preserved snapshot.
            self.logger.error(
                "Failed to lock implicit-latest preservation for reading; falling back to unlocked read: \(error)")
            let watermark = self.readImplicitLatestInvalidationWatermarkUnlocked()
            return self.validImplicitLatestPreservationUnlocked(watermark: watermark)
        }
    }

    private func validImplicitLatestPreservationUnlocked(
        watermark: Date?) -> SnapshotImplicitLatestPreservation?
    {
        guard let preservation = self.readImplicitLatestPreservationUnlocked(),
              self.validPreservationSnapshotURL(for: preservation.snapshotId) != nil,
              watermark.map({ $0 <= preservation.invalidatedThrough }) ?? true
        else { return nil }
        return preservation
    }

    private func readImplicitLatestPreservationUnlocked() -> SnapshotImplicitLatestPreservation? {
        guard let data = try? Data(contentsOf: self.implicitLatestPreservationURL) else { return nil }
        return try? JSONDecoder().decode(SnapshotImplicitLatestPreservation.self, from: data)
    }

    private func validPreservationSnapshotURL(for snapshotId: String) -> URL? {
        guard let candidate = self.safeSnapshotURL(for: snapshotId) else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.appendingPathComponent("snapshot.json").path)
        else { return nil }
        return candidate
    }

    private func safeSnapshotURL(for snapshotId: String) -> URL? {
        guard !snapshotId.isEmpty, snapshotId != ".", snapshotId != ".." else { return nil }
        let root = self.getSnapshotStorageURL().resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(snapshotId, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard candidate.deletingLastPathComponent().path == root.path else { return nil }
        return candidate
    }

    func removeSnapshotAndPreservation(snapshotId: String) throws -> Bool {
        guard let snapshotURL = self.safeSnapshotURL(for: snapshotId) else {
            throw SnapshotError.storageError("Invalid snapshot ID")
        }
        return try self.withImplicitLatestInvalidationLock(mode: .write) {
            let existed = FileManager.default.fileExists(atPath: snapshotURL.path)
            if existed {
                try FileManager.default.removeItem(at: snapshotURL)
            }
            if self.readImplicitLatestPreservationUnlocked()?.snapshotId == snapshotId {
                try? FileManager.default.removeItem(at: self.implicitLatestPreservationURL)
            }
            return existed
        }
    }

    func clearImplicitLatestPreservation(ifMatching snapshotId: String) throws {
        try self.withImplicitLatestInvalidationLock(mode: .write) {
            guard self.readImplicitLatestPreservationUnlocked()?.snapshotId == snapshotId else { return }
            try? FileManager.default.removeItem(at: self.implicitLatestPreservationURL)
        }
    }

    func clearImplicitLatestInvalidationWatermark() throws {
        try self.withImplicitLatestInvalidationLock(mode: .write) {
            let url = self.implicitLatestInvalidationWatermarkURL
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let preservationURL = self.implicitLatestPreservationURL
            if FileManager.default.fileExists(atPath: preservationURL.path) {
                try FileManager.default.removeItem(at: preservationURL)
            }
        }
    }

    private func withImplicitLatestInvalidationLock<T>(
        mode: SnapshotStateLockMode,
        _ body: () throws -> T) throws -> T
    {
        // Keep lock bodies synchronous and use only *Unlocked helpers; flock is not recursively safe.
        let lockURL = self.implicitLatestInvalidationLockURL
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: lockURL.path])
        }
        defer { close(descriptor) }

        guard flock(descriptor, mode.operation) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: lockURL.path])
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    func findLatestValidSnapshot(createdAtOrBefore latestCreationDate: Date? = nil) async -> String? {
        guard let state = self.latestSnapshotReadState(createdAtOrBefore: latestCreationDate) else {
            return nil
        }

        let latest = state.candidates.first
        if let preservation = state.preservation,
           preservation.preservedAt > state.cutoff,
           latestCreationDate.map({ preservation.preservedAt <= $0 }) ?? true,
           latest.map({ $0.createdAt <= preservation.preservedAt }) ?? true
        {
            return preservation.snapshotId
        }
        if let latest {
            let age = Int(-latest.createdAt.timeIntervalSinceNow)
            self.logger.debug(
                "Found valid snapshot: \(latest.url.lastPathComponent) created \(age) seconds ago")
            return latest.url.lastPathComponent
        } else {
            self.logger.debug("No valid snapshots found within \(Int(self.snapshotValidityWindow)) second window")
            return nil
        }
    }

    func findLatestValidSnapshot(applicationBundleId: String) async -> String? {
        guard let state = self.latestSnapshotReadState() else {
            return nil
        }

        var normalLatest: SnapshotLatestCandidate?
        for entry in state.candidates {
            let snapshotId = entry.url.lastPathComponent
            guard let snapshotData = await self.snapshotActor.loadSnapshot(snapshotId: snapshotId, from: entry.url)
            else { continue }
            if snapshotData.applicationBundleId == applicationBundleId {
                normalLatest = entry
                break
            }
        }

        if let preservation = state.preservation,
           preservation.preservedAt > state.cutoff,
           normalLatest.map({ $0.createdAt <= preservation.preservedAt }) ?? true
        {
            let snapshotURL = self.getSnapshotPath(for: preservation.snapshotId)
            if let snapshotData = await self.snapshotActor.loadSnapshot(
                snapshotId: preservation.snapshotId,
                from: snapshotURL),
                snapshotData.applicationBundleId == applicationBundleId
            {
                return preservation.snapshotId
            }
        }

        return normalLatest?.url.lastPathComponent
    }

    private func latestSnapshotReadState(
        createdAtOrBefore latestCreationDate: Date? = nil) -> SnapshotLatestReadState?
    {
        let sharedWatermark = self.desktopMutationWatermarkStore?.effectiveWatermark()
        do {
            return try self.withImplicitLatestInvalidationLock(mode: .read) {
                self.latestSnapshotReadStateUnlocked(
                    createdAtOrBefore: latestCreationDate,
                    sharedWatermark: sharedWatermark)
            }
        } catch {
            // A transient lock failure must not hide every cached snapshot. Watermark and
            // preservation files are written atomically, so an unlocked read is a safe best effort.
            self.logger.error(
                "Failed to lock snapshot state for latest-snapshot read; falling back to unlocked read: \(error)")
            return self.latestSnapshotReadStateUnlocked(
                createdAtOrBefore: latestCreationDate,
                sharedWatermark: sharedWatermark)
        }
    }

    private func latestSnapshotReadStateUnlocked(
        createdAtOrBefore latestCreationDate: Date?,
        sharedWatermark: Date?) -> SnapshotLatestReadState?
    {
        let snapshotDir = self.getSnapshotStorageURL()
        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: snapshotDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles)
        else {
            return nil
        }

        let cutoff = Date().addingTimeInterval(-self.snapshotValidityWindow)
        let watermark = Self.latestWatermark(
            self.readImplicitLatestInvalidationWatermarkUnlocked(),
            sharedWatermark)
        let candidates = snapshots.compactMap { url -> SnapshotLatestCandidate? in
            guard let values = try? url.resourceValues(forKeys: [.creationDateKey]),
                  let createdAt = self.snapshotCreationDate(at: url, fallback: values.creationDate),
                  createdAt > cutoff,
                  watermark.map({ createdAt > $0 }) ?? true,
                  latestCreationDate.map({ createdAt <= $0 }) ?? true,
                  url.hasDirectoryPath,
                  !self.isPendingSnapshot(at: url),
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("snapshot.json").path)
            else {
                return nil
            }
            return SnapshotLatestCandidate(url: url, createdAt: createdAt)
        }.sorted { $0.createdAt > $1.createdAt }
        let preservation = self.validImplicitLatestPreservationUnlocked(watermark: watermark)
        return SnapshotLatestReadState(
            cutoff: cutoff,
            candidates: candidates,
            preservation: preservation)
    }

    func convertElementTypeToRole(_ type: ElementType) -> String {
        switch type {
        case .button: "AXButton"
        case .textField: "AXTextField"
        case .link: "AXLink"
        case .image: "AXImage"
        case .group: "AXGroup"
        case .slider: "AXSlider"
        case .checkbox: "AXCheckBox"
        case .menu: "AXMenu"
        case .staticText: "AXStaticText"
        case .radioButton: "AXRadioButton"
        case .menuItem: "AXMenuItem"
        case .window: "AXWindow"
        case .dialog: "AXDialog"
        case .other: "AXUnknown"
        }
    }

    func convertRoleToElementType(_ role: String) -> ElementType {
        switch role {
        case "AXButton": .button
        case "AXTextField", "AXTextArea": .textField
        case "AXLink": .link
        case "AXImage": .image
        case "AXGroup": .group
        case "AXSlider": .slider
        case "AXCheckBox": .checkbox
        case "AXMenu", "AXMenuItem": .menu
        default: .other
        }
    }

    func isActionableType(_ type: ElementType) -> Bool {
        switch type {
        case .button, .textField, .link, .checkbox, .slider, .menu, .menuItem, .radioButton:
            true
        case .image, .group, .other, .staticText, .window, .dialog:
            false
        }
    }

    func organizeElementsByType(_ elements: [DetectedElement]) -> DetectedElements {
        var buttons: [DetectedElement] = []
        var textFields: [DetectedElement] = []
        var links: [DetectedElement] = []
        var images: [DetectedElement] = []
        var groups: [DetectedElement] = []
        var sliders: [DetectedElement] = []
        var checkboxes: [DetectedElement] = []
        var menus: [DetectedElement] = []
        var other: [DetectedElement] = []

        for element in elements {
            switch element.type {
            case .button: buttons.append(element)
            case .textField: textFields.append(element)
            case .link: links.append(element)
            case .image: images.append(element)
            case .group: groups.append(element)
            case .slider: sliders.append(element)
            case .checkbox: checkboxes.append(element)
            case .menu, .menuItem: menus.append(element)
            case .other, .staticText, .radioButton, .window, .dialog: other.append(element)
            }
        }

        return DetectedElements(
            buttons: buttons,
            textFields: textFields,
            links: links,
            images: images,
            groups: groups,
            sliders: sliders,
            checkboxes: checkboxes,
            menus: menus,
            other: other)
    }

    func applyWindowContext(_ context: WindowContext, to snapshotData: inout UIAutomationSnapshot) {
        snapshotData.applicationName = context.applicationName ?? snapshotData.applicationName
        snapshotData.applicationBundleId = context.applicationBundleId ?? snapshotData.applicationBundleId
        snapshotData.applicationProcessId = context.applicationProcessId ?? snapshotData.applicationProcessId
        snapshotData.windowTitle = context.windowTitle ?? snapshotData.windowTitle
        snapshotData.windowBounds = context.windowBounds ?? snapshotData.windowBounds
        if let windowID = context.windowID {
            snapshotData.windowID = CGWindowID(windowID)
        }
    }

    func applyLegacyWarnings(_ warnings: [String], to snapshotData: inout UIAutomationSnapshot) {
        for warning in warnings {
            if warning.hasPrefix("APP:") || warning.hasPrefix("app:") {
                snapshotData.applicationName = String(warning.dropFirst(4))
            } else if warning.hasPrefix("WINDOW:") || warning.hasPrefix("window:") {
                snapshotData.windowTitle = String(warning.dropFirst(7))
            } else if warning.hasPrefix("BOUNDS:"),
                      let boundsData = String(warning.dropFirst(7)).data(using: .utf8),
                      let bounds = try? JSONDecoder().decode(CGRect.self, from: boundsData)
            {
                snapshotData.windowBounds = bounds
            } else if warning.hasPrefix("WINDOW_ID:"),
                      let windowID = CGWindowID(String(warning.dropFirst(10)))
            {
                snapshotData.windowID = windowID
            } else if warning.hasPrefix("AX_IDENTIFIER:") {
                snapshotData.windowAXIdentifier = String(warning.dropFirst(14))
            }
        }
    }

    func buildWarnings(from snapshotData: UIAutomationSnapshot) -> [String] {
        var warnings: [String] = []
        if let appName = snapshotData.applicationName {
            warnings.append("APP:\(appName)")
        }
        if let windowTitle = snapshotData.windowTitle {
            warnings.append("WINDOW:\(windowTitle)")
        }
        if let windowBounds = snapshotData.windowBounds,
           let boundsData = try? JSONEncoder().encode(windowBounds),
           let boundsString = String(data: boundsData, encoding: .utf8)
        {
            warnings.append("BOUNDS:\(boundsString)")
        }
        if let windowID = snapshotData.windowID {
            warnings.append("WINDOW_ID:\(windowID)")
        }
        if let axIdentifier = snapshotData.windowAXIdentifier {
            warnings.append("AX_IDENTIFIER:\(axIdentifier)")
        }
        return warnings
    }

    func windowContext(from snapshotData: UIAutomationSnapshot) -> WindowContext? {
        guard snapshotData.applicationName != nil ||
            snapshotData.applicationBundleId != nil ||
            snapshotData.applicationProcessId != nil ||
            snapshotData.windowTitle != nil ||
            snapshotData.windowID != nil ||
            snapshotData.windowBounds != nil
        else {
            return nil
        }

        return WindowContext(
            applicationName: snapshotData.applicationName,
            applicationBundleId: snapshotData.applicationBundleId,
            applicationProcessId: snapshotData.applicationProcessId,
            windowTitle: snapshotData.windowTitle,
            windowID: snapshotData.windowID.map(Int.init),
            windowBounds: snapshotData.windowBounds)
    }

    func countScreenshots(in snapshotURL: URL) -> Int {
        let files = try? FileManager.default.contentsOfDirectory(at: snapshotURL, includingPropertiesForKeys: nil)
        return files?.count(where: { $0.pathExtension == "png" }) ?? 0
    }

    func calculateDirectorySize(_ url: URL) -> Int64 {
        var totalSize: Int64 = 0

        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles])
        {
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = resourceValues.fileSize
                {
                    totalSize += Int64(fileSize)
                }
            }
        }

        return totalSize
    }

    func extractProcessId(from snapshotId: String) -> Int32 {
        // Try to extract PID from old-style snapshot IDs (just numbers)
        if let pid = Int32(snapshotId) {
            return pid
        }
        // For new timestamp-based IDs, return 0
        return 0
    }

    func isProcessActive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}
