import Foundation

public enum PeekabooBridgeConstants {
    public static let socketName = "bridge.sock"
    public static let cliBundleIdentifier = "boo.peekaboo.peekaboo"

    /// Release identities accepted during the OpenClaw Foundation signing migration.
    /// Keep the legacy team while standalone CLIs must interoperate with pre-3.8 GUI hosts.
    public static let trustedReleaseTeamIDs: Set<String> = ["Y5PE65HELJ", "FWJYW4S8P8"]

    /// Socket hosted by Peekaboo.app (primary host).
    public static var peekabooSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "Peekaboo", socketName: self.socketName)
    }

    /// Socket hosted by the reusable on-demand or manually started daemon.
    public static var daemonSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "Peekaboo", socketName: "daemon.sock")
    }

    /// Socket hosted by Claude.app (fallback host; piggyback on Claude Desktop TCC grants).
    public static var claudeSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "Claude", socketName: self.socketName)
    }

    /// Socket hosted by Clawdbot.app (fallback host).
    public static var clawdbotSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "clawdbot", socketName: self.socketName)
    }

    /// Default host-signing policy for sockets owned by bundled Peekaboo runtimes.
    ///
    /// Arbitrary socket paths deliberately return `nil`: protocol 1.29 callers must name the
    /// teams they trust instead of treating possession of a per-user filesystem path as host
    /// authentication.
    public static func defaultTrustedHostTeamIDs(socketPath: String) -> Set<String>? {
        let standardized = NSString(string: socketPath).standardizingPath
        let exactPaths = [
            self.peekabooSocketPath,
            self.daemonSocketPath,
            self.claudeSocketPath,
            self.clawdbotSocketPath,
        ].map { NSString(string: $0).standardizingPath }
        if exactPaths.contains(standardized) {
            return self.trustedReleaseTeamIDs
        }

        let url = URL(fileURLWithPath: standardized)
        let daemonDirectory = URL(fileURLWithPath: self.daemonSocketPath)
            .deletingLastPathComponent().standardizedFileURL.path
        let filename = url.lastPathComponent
        let prefix = "daemon-"
        let suffix = ".sock"
        guard url.deletingLastPathComponent().standardizedFileURL.path == daemonDirectory,
              filename.hasPrefix(prefix),
              filename.hasSuffix(suffix)
        else { return nil }
        let hashStart = filename.index(filename.startIndex, offsetBy: prefix.count)
        let hashEnd = filename.index(filename.endIndex, offsetBy: -suffix.count)
        let hash = filename[hashStart..<hashEnd]
        guard hash.count == 16,
              hash.allSatisfy(\.isHexDigit)
        else { return nil }
        return self.trustedReleaseTeamIDs
    }

    /// Current protocol version supported by this build.
    public static let protocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 34)

    /// First protocol that can attest one exact Chrome bundle, process generation, listener, and DevTools identity.
    public static let nativeBrowserConnectionBindingVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 34)

    /// First protocol that can negotiate producer-bound snapshot references without exposing a
    /// new operation to already-shipped 1.34 clients that did not offer the raw capability.
    public static let producerBoundSnapshotReferencesVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 34)

    /// First protocol that can explicitly negotiate and enforce the AXFocused value-delivery policy for clicks.
    public static let targetedClickAccessibilityValueDeliveryVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 34)

    /// First protocol with host-atomic exact-window pixel-focus typing and modifier-click payloads.
    public static let composedInputParityVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 33)

    /// First protocol with a receipt-required, host-derived exact process-generation observation.
    public static let processGenerationObservationVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 32)

    /// First protocol with receipt-bound, host-authenticated certification producer evidence.
    public static let certificationProducerAttestationVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 32)

    /// First protocol whose set-value result preserves the exact opaque request target so its
    /// signed response can be bound to the request without post-dispatch ambiguity.
    public static let setValueResultTargetBindingVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 32)

    /// First protocol whose Bridge can launch the exact authenticated CLI peer as a suspended
    /// background Agent and return one listener-signed terminal execution trace.
    public static let agentExecutionTraceVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 31)

    /// First protocol that transports mutation-planner inventories with explicit completeness evidence.
    public static let plannerInventoryTransportVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 30)

    /// First protocol with owner-scoped exact-window held-pointer lifecycles.
    public static let exactWindowHeldPointerLifecycleVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 30)

    /// First protocol whose click payload can carry stateless middle- and triple-click variants.
    public static let statelessClickVariantVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 30)

    /// First protocol with listener-bound, signed per-operation receipts.
    public static let attestedOperationReceiptVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 29)

    /// First protocol with atomic host-side execution of an exact dialog input request.
    public static let exactDialogInputExecutionVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 27)

    /// First protocol with selector-preserving, host-atomic forced dialog dismissal.
    public static let exactForcedDialogDismissExecutionVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 28)

    /// First protocol whose legacy current-dialog input payload carries an explicit focus policy.
    public static let dialogInputFocusPolicyVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 28)

    /// First protocol with published snapshots that remain explicit-reference-only.
    public static let explicitSnapshotPublicationVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 26)

    /// First protocol whose browser connection is probed and pinned to one exact Chrome identity.
    public static let browserConnectionReceiptVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 26)

    /// First protocol with host-retained, one-shot exact dialog/button action receipts.
    public static let receiptPinnedDialogActionVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 25)

    /// First protocol with host-owned, fail-closed leases for snapshot-backed mutations.
    public static let snapshotMutationLeaseVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 24)

    /// First protocol with explicit per-request canonical desktop-action outcome carriage.
    public static let desktopActionOutcomeProjectionVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 23)

    /// First protocol that carries process-generation receipts with process-targeted typing and clicks.
    public static let processGenerationPinnedInteractionVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 22)

    /// First protocol whose desktop-observation payload and response preserve exact-window ROI
    /// requests, cropped viewport metadata, and snapshot coordinate context end to end.
    public static let exactWindowROIObservationVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 21)

    /// First protocol with one host-owned transaction for an observation snapshot's raster,
    /// element map, and optional annotation.
    public static let atomicObservationSnapshotPublicationVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 21)

    /// First protocol that carries an application process-generation receipt with quit requests.
    public static let processGenerationPinnedApplicationQuitVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 16)

    /// First protocol that signs caller-pinned application hide requests and results.
    public static let processGenerationPinnedApplicationHideVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 29)

    /// First protocol that carries a process-generation receipt with targeted hotkey requests.
    public static let processGenerationPinnedHotkeyVersion =
        PeekabooBridgeProtocolVersion(major: 1, minor: 19)

    /// Oldest protocol version this build can serve without changing request semantics.
    public static let minimumProtocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 0)

    /// Compatible protocol range for negotiation. Update when introducing breaking changes.
    public static let supportedProtocolRange: ClosedRange<PeekabooBridgeProtocolVersion> =
        minimumProtocolVersion...protocolVersion

    /// Default deadline for one Bridge request or response.
    public static let defaultRequestTimeoutSeconds: TimeInterval = 10

    /// Build identifier advertised during handshake (falls back to "dev").
    public static var buildIdentifier: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleVersion"] as? String
        let short = info?["CFBundleShortVersionString"] as? String
        switch (short, version) {
        case let (short?, version?):
            return "\(short) (\(version))"
        case let (nil, version?):
            return version
        default:
            return "dev"
        }
    }

    private static func applicationSupportSocketPath(appDirectoryName: String, socketName: String) -> String {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = baseDirectory.appendingPathComponent(appDirectoryName, isDirectory: true)
        return directory.appendingPathComponent(socketName, isDirectory: false).path
    }
}

extension JSONEncoder {
    public static func peekabooBridgeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Keep legacy 1.0–1.8 date fields wire-compatible. Ordering-sensitive 1.9 fields use
        // model-specific numeric reference-date encoding so they retain subsecond precision.
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static func peekabooBridgeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = PeekabooBridgeDateCoding.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid Peekaboo Bridge ISO-8601 date: \(value)")
            }
            return date
        }
        return decoder
    }
}

private enum PeekabooBridgeDateCoding {
    static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        guard let decimalIndex = value.firstIndex(of: ".") else {
            return formatter.date(from: value)
        }
        let fractionalStart = value.index(after: decimalIndex)
        let fractionalEnd = value[fractionalStart...].firstIndex(where: { !$0.isNumber }) ?? value.endIndex
        let fractionalDigits = value[fractionalStart..<fractionalEnd]
        guard !fractionalDigits.isEmpty,
              let fraction = Double("0.\(fractionalDigits)")
        else {
            return nil
        }

        let wholeSecondsValue = String(value[..<decimalIndex] + value[fractionalEnd...])
        guard let wholeSeconds = formatter.date(from: wholeSecondsValue) else {
            return nil
        }
        return wholeSeconds.addingTimeInterval(fraction)
    }
}
