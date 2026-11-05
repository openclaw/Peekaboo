import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    func fileSelectionMetadata(
        _ element: Element,
        execution: FileExecution?,
        budget: DialogOperationDeadline) async throws -> DialogFileSelectionMetadata
    {
        if let execution {
            return try await self.discoveryReaders.fileSelection(
                element, execution.target.identity.processIdentity, budget)
        }
        return DialogFileSelectionMetadata.readDirect(element)
    }

    /// A bare stem counts only when the panel would display it, so a parent folder named like the file is not evidence.
    nonisolated static func fileDialogSelectionNames(
        path: String,
        displayName: (String) -> String = { FileManager.default.displayName(atPath: $0) }) -> Set<String>
    {
        [URL(fileURLWithPath: path).lastPathComponent.lowercased(), displayName(path).lowercased()]
    }

    func fileDialogHasSelectedFile(
        _ path: String,
        in dialog: Element,
        execution: FileExecution? = nil,
        budget: DialogOperationDeadline) async throws -> Bool
    {
        let names = Self.fileDialogSelectionNames(path: path)
        return try await self.visitFileDialogTree(from: dialog, execution: execution, budget: budget) { element, _ in
            let metadata = try await self.fileSelectionMetadata(element, execution: execution, budget: budget)
            let selectedItems = metadata.selectedItems + (metadata.isSelected ? [element] : [])
            for item in selectedItems {
                let matches = try await self.visitFileDialogTree(
                    from: item,
                    execution: execution,
                    budget: budget,
                    maximumDepth: 4,
                    allowRootDialog: false,
                    visit: { descendant, _ in
                        let metadata = try await self.fileSelectionMetadata(
                            descendant, execution: execution, budget: budget)
                        return metadata.names.contains { names.contains($0.lowercased()) } ? .matched : .descend
                    })
                if matches {
                    return .matched
                }
            }
            // A container that reports its selection needs no row-by-row walk; large folders must fit the budget.
            return metadata.selectedItems.isEmpty ? .descend : .skipChildren
        }
    }

    func verifyFileSelection(
        _ path: String,
        in dialog: Element,
        execution: FileExecution? = nil) async throws
    {
        let budget = try DialogOperationDeadline.bounded(
            timeoutSeconds: 3,
            operationName: "file selection verification")
        do {
            repeat {
                if try await self.fileDialogHasSelectedFile(path, in: dialog, execution: execution, budget: budget) {
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            } while budget.remainingSeconds > 0
        } catch let error as PeekabooError {
            guard case .timeout = error else { throw error }
        }
        throw DialogError.fileSelectionNotVerified(path: path)
    }

    func confirmFileDialog(
        in dialog: Element,
        buttonText: String,
        selectedFile: String?,
        execution: FileExecution? = nil) async throws -> DialogActionResult
    {
        if let selectedFile {
            try await self.verifyFileSelection(selectedFile, in: dialog, execution: execution)
        }
        return try await self.clickButton(
            in: dialog,
            buttonText: buttonText,
            allowFallbackToDefaultAction: true,
            allowGlobalFallback: true,
            execution: execution)
    }
}
