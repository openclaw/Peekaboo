import Foundation

enum Version {
    private static let values = VersionMetadata.resolve()

    static let current = values.current
    static let gitCommit = values.gitCommit
    static let gitCommitDate = values.gitCommitDate
    static let gitBranch = values.gitBranch
    static let buildDate = values.buildDate

    static var fullVersion: String {
        "\(current) (\(gitBranch)/\(gitCommit), built: \(buildDate))"
    }
}

private enum VersionMetadata {
    struct Values {
        let current: String
        let gitCommit: String
        let gitCommitDate: String
        let gitBranch: String
        let buildDate: String
    }

    static func resolve() -> Values {
        if let info = valuesFromInfoDictionary() {
            return info
        }

        return Values(
            current: "Peekaboo 0.0.0",
            gitCommit: "unknown",
            gitCommitDate: "unknown",
            gitBranch: "unknown",
            buildDate: "unknown"
        )
    }

    private static func valuesFromInfoDictionary() -> Values? {
        guard let info = Bundle.main.infoDictionary else { return nil }

        guard let shortVersion = info["CFBundleShortVersionString"] as? String else {
            return nil
        }

        let display = info["PeekabooVersionDisplayString"] as? String ?? "Peekaboo \(shortVersion)"

        return Values(
            current: display,
            gitCommit: self.metadataValue("PeekabooGitCommit", in: info),
            gitCommitDate: self.metadataValue("PeekabooGitCommitDate", in: info),
            gitBranch: self.metadataValue("PeekabooGitBranch", in: info),
            buildDate: self.metadataValue("PeekabooBuildDate", in: info)
        )
    }

    private static func metadataValue(_ key: String, in info: [String: Any]) -> String {
        guard let rawValue = info[key] as? String else { return "unknown" }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "unknown" : value
    }
}
