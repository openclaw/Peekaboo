extension PeekabooBridgeOperationReceiptSemantics {
    static func validateOpaqueBrowserTarget(
        _ target: PeekabooBridgeOperationTargetReceipt?,
        operation: PeekabooBridgeOperation) throws -> Bool
    {
        switch target {
        case .browserCapabilityNamespace:
            guard operation == .browserCapabilityNamespace else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "browser namespace target used outside namespace execution")
            }
            return true
        case .browser:
            guard [PeekabooBridgeOperation.browserConnect, .browserExecute].contains(operation) else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "browser target used outside external browser execution")
            }
            return false
        case .global, .process, .window, nil:
            return false
        }
    }
}
