extension BrowserToolCapabilitySession {
    func withExclusiveOperation<Result: Sendable>(
        _ operation: @MainActor @Sendable () async throws -> Result) async throws -> Result
    {
        try await self.operationGate.acquire()
        guard !self.ended else {
            await self.operationGate.release()
            throw BrowserToolCapabilityError.sessionEnded
        }
        do {
            let result = try await operation()
            await self.operationGate.release()
            return result
        } catch {
            await self.operationGate.release()
            throw error
        }
    }
}
