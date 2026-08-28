import Foundation
import PeekabooFoundation

/// Check if the CLI binary is stale compared to the current git state.
/// Only runs in debug builds when git config 'peekaboo.check-build-staleness' is true.
func checkBuildStaleness() {
    guard isBuildStalenessCheckEnabled() else { return }

    // Check 1: Git commit comparison
    checkGitCommitStaleness()

    // Check 2: File modification time comparison
    checkFileModificationStaleness()
}

/// Return true when `peekaboo.check-build-staleness` is enabled.
///
/// This runs on every debug CLI start, so avoid spawning `git config` for the common
/// disabled path. Environment override keeps a cheap opt-in for CI and local debugging.
func isBuildStalenessCheckEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectory: String = FileManager.default.currentDirectoryPath,
    gitConfigPaths: [String]? = nil
) -> Bool {
    if let override = environment["PEEKABOO_CHECK_BUILD_STALENESS"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
        !override.isEmpty {
        return override == "1" || override == "true" || override == "yes"
    }

    var setting: Bool?
    for path in gitConfigPaths ?? defaultGitConfigPaths(environment: environment, currentDirectory: currentDirectory) {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let parsedSetting = parseBuildStalenessSetting(from: contents)
        else {
            continue
        }
        setting = parsedSetting
    }

    return setting == true
}

func parseBuildStalenessSetting(from gitConfig: String) -> Bool? {
    var inPeekabooSection = false

    for rawLine in gitConfig.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }

        if line.hasPrefix("[") && line.hasSuffix("]") {
            let section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            inPeekabooSection = section == "peekaboo"
            continue
        }

        guard inPeekabooSection else { continue }
        let parts = line.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard parts.count == 2, parts[0] == "check-build-staleness" else { continue }
        return parts[1] == "true" || parts[1] == "1" || parts[1] == "yes"
    }

    return nil
}

private func defaultGitConfigPaths(environment: [String: String], currentDirectory: String) -> [String] {
    var paths = ["/etc/gitconfig"]

    if let xdgConfigHome = environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
        paths.append(URL(fileURLWithPath: xdgConfigHome).appendingPathComponent("git/config").path)
    } else if let home = environment["HOME"], !home.isEmpty {
        paths.append(URL(fileURLWithPath: home).appendingPathComponent(".config/git/config").path)
    }

    if let home = environment["HOME"], !home.isEmpty {
        paths.append(URL(fileURLWithPath: home).appendingPathComponent(".gitconfig").path)
    }

    if let localConfigPath = findGitConfigPath(startingAt: URL(fileURLWithPath: currentDirectory, isDirectory: true)) {
        paths.append(localConfigPath)
    }

    return paths
}

func findGitConfigPath(startingAt directory: URL, fileManager: FileManager = .default) -> String? {
    var components = directory.standardizedFileURL.pathComponents

    // Consume one component per ancestor, including root, without asking for root's parent.
    while !components.isEmpty {
        let directory = URL(fileURLWithPath: NSString.path(withComponents: components), isDirectory: true)
        components.removeLast()
        let dotGit = directory.appendingPathComponent(".git").path
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return URL(fileURLWithPath: dotGit).appendingPathComponent("config").path
            }

            if let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
               let gitDirLine = contents.components(separatedBy: .newlines).first(where: {
                   $0.trimmingCharacters(in: .whitespaces).hasPrefix("gitdir:")
               }) {
                let rawGitDir = gitDirLine
                    .replacingOccurrences(of: "gitdir:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let gitDirURL = URL(fileURLWithPath: rawGitDir, relativeTo: directory).standardizedFileURL
                return gitDirURL.appendingPathComponent("config").path
            }
        }
    }

    return nil
}

/// Check if the embedded git commit differs from the current git commit
private func checkGitCommitStaleness() {
    // Raw SwiftPM builds intentionally omit exact provenance, so avoid spawning Git for them.
    let embeddedCommit = Version.sourceCommit
    guard shouldCheckGitCommitStaleness(embeddedCommit: embeddedCommit) else {
        return
    }

    // Get current git commit hash
    let gitProcess = Process()
    gitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    gitProcess.arguments = ["rev-parse", "HEAD"]

    let gitPipe = Pipe()
    gitProcess.standardOutput = gitPipe
    gitProcess.standardError = Pipe() // Silence stderr

    do {
        try gitProcess.run()
        gitProcess.waitUntilExit()

        guard gitProcess.terminationStatus == 0 else {
            return // Git command failed, skip check
        }

        let gitData = gitPipe.fileHandleForReading.readDataToEndOfFile()
        let rawCommitString = String(data: gitData, encoding: .utf8)
        let currentCommit = rawCommitString?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Compare commits
        if !currentCommit.isEmpty && currentCommit != embeddedCommit {
            logError("❌ CLI binary is outdated and needs to be rebuilt!")
            logError("   Built with commit: \(embeddedCommit)")
            logError("   Current commit:    \(currentCommit)")
            logError("")
            logError("   Run ./scripts/build-swift-debug.sh to rebuild")
            exit(1)
        }
    } catch {
        return // Git command failed, skip check
    }
}

func shouldCheckGitCommitStaleness(embeddedCommit: String) -> Bool {
    SourceProvenance.exactCommit(embeddedCommit) != nil
}

/// Check if any tracked files have been modified after the build time
private func checkFileModificationStaleness() {
    // Parse build date from Version.buildDate (ISO 8601 format)
    let dateFormatter = ISO8601DateFormatter()
    guard let buildDate = dateFormatter.date(from: Version.buildDate) else {
        return // Could not parse build date, skip check
    }

    // Get git repository root
    guard let gitRoot = getGitRepositoryRoot() else {
        return // Could not determine git root, skip check
    }

    // Get list of modified files from git status
    let gitStatusProcess = Process()
    gitStatusProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    gitStatusProcess.arguments = ["status", "--porcelain=1"]

    let statusPipe = Pipe()
    gitStatusProcess.standardOutput = statusPipe
    gitStatusProcess.standardError = Pipe() // Silence stderr

    do {
        try gitStatusProcess.run()
        gitStatusProcess.waitUntilExit()

        guard gitStatusProcess.terminationStatus == 0 else {
            return // Git command failed, skip check
        }

        let statusData = statusPipe.fileHandleForReading.readDataToEndOfFile()
        let statusOutput = String(data: statusData, encoding: .utf8) ?? ""

        // Parse git status output
        let modifiedFiles = parseGitStatusOutput(statusOutput)

        // Check each modified file's modification time
        for filePath in modifiedFiles where
            isFileNewerThanBuild(filePath: filePath, buildDate: buildDate, gitRoot: gitRoot) {
            logError("❌ CLI binary is outdated and needs to be rebuilt!")
            logError("   Build time:     \(Version.buildDate)")
            logError("   Modified file:  \(filePath)")
            logError("")
            logError("   Run ./scripts/build-swift-debug.sh to rebuild")
            exit(1)
        }
    } catch {
        return // Git command failed, skip check
    }
}

/// Parse git status --porcelain=1 output to extract file paths
/// Format: "XY filename" or "XY orig_path -> new_path" for renames
private func parseGitStatusOutput(_ output: String) -> [String] {
    // Parse git status --porcelain=1 output to extract file paths
    let lines = output.components(separatedBy: .newlines)
    var filePaths: [String] = []

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        // Git status format: "XY filename" or "XY orig_path -> new_path"
        // X = staged status, Y = working tree status
        guard trimmed.count >= 3 else { continue }

        let statusCodes = String(trimmed.prefix(2))
        var filePath = String(trimmed.dropFirst(2)) // Skip "XY"

        // Remove leading space if present
        if filePath.hasPrefix(" ") {
            filePath = String(filePath.dropFirst())
        }

        // Include files that are modified (M), added (A), or have other changes
        // Skip deleted files (D) since they can't be newer than build
        if statusCodes.contains("M") || statusCodes.contains("A") || statusCodes.contains("R") || statusCodes
            .contains("C") || statusCodes.contains("U") {
            // Handle renamed files: "orig_path -> new_path"
            // For renames, we want to check the new path
            if filePath.contains(" -> ") {
                let components = filePath.components(separatedBy: " -> ")
                if components.count == 2 {
                    filePath = components[1] // Use the new path
                }
            }

            // Handle quoted paths (git quotes paths with special characters)
            let cleanPath = filePath.hasPrefix("\"") && filePath.hasSuffix("\"")
                ? String(filePath.dropFirst().dropLast())
                : filePath
            filePaths.append(cleanPath)
        }
    }

    return filePaths
}

/// Get the git repository root directory
private func getGitRepositoryRoot() -> String? {
    // Get the git repository root directory
    let gitProcess = Process()
    gitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    gitProcess.arguments = ["rev-parse", "--show-toplevel"]

    let pipe = Pipe()
    gitProcess.standardOutput = pipe
    gitProcess.standardError = Pipe() // Silence stderr

    do {
        try gitProcess.run()
        gitProcess.waitUntilExit()

        guard gitProcess.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Check if output is empty after trimming
        guard let output, !output.isEmpty else {
            return nil
        }
        return output
    } catch {
        return nil
    }
}

/// Check if a file's modification time is newer than the build date
private func isFileNewerThanBuild(filePath: String, buildDate: Date, gitRoot: String) -> Bool {
    // Check if a file's modification time is newer than the build date
    let fileManager = FileManager.default
    // Git status paths are relative to repository root, not current directory
    let fullPath = (filePath.hasPrefix("/")) ? filePath : "\(gitRoot)/\(filePath)"

    do {
        let attributes = try fileManager.attributesOfItem(atPath: fullPath)
        if let modificationDate = attributes[.modificationDate] as? Date {
            return modificationDate > buildDate
        }
    } catch {
        // File might not exist or be accessible, skip this check
        return false
    }

    return false
}
