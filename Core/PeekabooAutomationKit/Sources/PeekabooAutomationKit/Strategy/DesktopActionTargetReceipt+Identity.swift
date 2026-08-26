import PeekabooFoundation

extension ApplicationProcessIdentity {
    public var actionTargetReceipt: DesktopActionTargetReceipt {
        DesktopActionTargetReceipt(
            processIdentifier: self.processIdentifier,
            processStartIdentity: self.processStartIdentity)
    }
}

extension WindowMutationIdentity {
    public var actionTargetReceipt: DesktopActionTargetReceipt {
        DesktopActionTargetReceipt(
            processIdentifier: self.ownerProcessIdentifier,
            processStartIdentity: self.ownerProcessStartIdentity,
            windowID: self.windowID)
    }

    /// A projection for optional or partially decoded evidence that must not synthesize an
    /// actionable receipt from zero-valued identity fields.
    public var validActionTargetReceipt: DesktopActionTargetReceipt? {
        guard self.ownerProcessIdentifier > 0,
              self.ownerProcessStartIdentity > 0,
              self.windowID > 0,
              self.windowID <= Int(UInt32.max)
        else {
            return nil
        }
        return self.actionTargetReceipt
    }
}

extension UIAutomationTarget.ExactWindow {
    public var actionTargetReceipt: DesktopActionTargetReceipt {
        self.identity.actionTargetReceipt
    }
}

extension DesktopTargetIdentity {
    public var actionTargetReceipt: DesktopActionTargetReceipt {
        self.exactWindow?.actionTargetReceipt ?? self.processIdentity.actionTargetReceipt
    }
}
