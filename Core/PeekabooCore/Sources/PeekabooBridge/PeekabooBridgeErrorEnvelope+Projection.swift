extension PeekabooBridgeErrorEnvelope {
    /// Removes negotiated canonical fields while retaining the conservative legacy dispatch bit.
    ///
    /// Old request shapes must receive the old response shape. Previous clients can still avoid
    /// an unsafe retry through `operationMayHaveCompleted`, while only projected requests receive
    /// the richer canonical failure.
    var legacyCompatible: PeekabooBridgeErrorEnvelope {
        PeekabooBridgeErrorEnvelope(
            code: self.code,
            message: self.message,
            details: self.details,
            permission: self.permission,
            kind: self.kind,
            context: self.context,
            operationMayHaveCompleted: self.operationMayHaveCompleted)
    }
}
