import Foundation
import PeekabooFoundation

enum Version {
    private static let values = VersionMetadata.resolve()

    static let metadata = values
    static let current = values.current
    static let gitCommit = values.gitCommit
    static let sourceCommit = values.sourceCommit
    static let gitCommitDate = values.gitCommitDate
    static let gitBranch = values.gitBranch
    static let buildDate = values.buildDate

    static var fullVersion: String {
        "\(current) (\(gitBranch)/\(gitCommit), built: \(buildDate))"
    }
}

enum VersionMetadata {
    struct Values: Codable, Equatable, Sendable {
        let current: String
        let gitCommit: String
        let sourceCommit: String
        let gitCommitDate: String
        let gitBranch: String
        let buildDate: String
    }

    static func resolve(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> Values {
        if let info = valuesFromInfoDictionary(infoDictionary) {
            return info
        }

        return Values(
            current: "Peekaboo 0.0.0",
            gitCommit: "unknown",
            sourceCommit: SourceProvenance.unknownCommit,
            gitCommitDate: "unknown",
            gitBranch: "unknown",
            buildDate: "unknown"
        )
    }

    private static func valuesFromInfoDictionary(_ info: [String: Any]?) -> Values? {
        guard let info else { return nil }
        guard let shortVersion = info["CFBundleShortVersionString"] as? String,
              !shortVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let display = self.nonemptyString(info["PeekabooVersionDisplayString"]) ?? "Peekaboo \(shortVersion)"

        return Values(
            current: display,
            gitCommit: self.metadataValue(info["PeekabooGitCommit"]),
            sourceCommit: SourceProvenance.normalizedCommit(info["PeekabooSourceCommit"] as? String),
            gitCommitDate: self.metadataValue(info["PeekabooGitCommitDate"]),
            gitBranch: self.metadataValue(info["PeekabooGitBranch"]),
            buildDate: self.metadataValue(info["PeekabooBuildDate"])
        )
    }

    private static func metadataValue(_ value: Any?) -> String {
        self.nonemptyString(value) ?? "unknown"
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}
