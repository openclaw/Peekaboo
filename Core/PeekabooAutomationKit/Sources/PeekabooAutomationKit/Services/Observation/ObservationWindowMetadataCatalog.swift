import CoreGraphics
import Foundation

public struct ExactWindowObservationMetadata: Sendable, Equatable {
    public let ownerProcessIdentifier: Int32
    public let ownerProcessStartIdentity: UInt64
    public let title: String
    public let bounds: CGRect
    public let applicationName: String?

    public init(
        ownerProcessIdentifier: Int32,
        ownerProcessStartIdentity: UInt64,
        title: String,
        bounds: CGRect,
        applicationName: String? = nil)
    {
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.ownerProcessStartIdentity = ownerProcessStartIdentity
        self.title = title
        self.bounds = bounds
        self.applicationName = applicationName
    }
}

public protocol ExactWindowMetadataProviding: Sendable {
    func metadata(for windowID: CGWindowID) -> ExactWindowObservationMetadata?
    func windows(for processIdentifier: Int32) -> [SystemWindowIdentity]
    func processStartIdentity(for processIdentifier: Int32) -> UInt64?
}

extension ExactWindowMetadataProviding {
    public func windows(for _: Int32) -> [SystemWindowIdentity] {
        []
    }

    public func processStartIdentity(for _: Int32) -> UInt64? {
        nil
    }
}

public struct SystemExactWindowMetadataProvider: ExactWindowMetadataProviding {
    public init() {}

    public func metadata(for windowID: CGWindowID) -> ExactWindowObservationMetadata? {
        guard let identity = SystemIdentityResolver.windowIdentity(windowID),
              let processStartIdentity = SystemIdentityResolver.processStartIdentity(
                  identity.ownerProcessIdentifier),
              SystemIdentityResolver.windowMutationIdentity(
                  windowID: windowID,
                  expectedOwnerProcessIdentifier: identity.ownerProcessIdentifier,
                  expectedOwnerProcessStartIdentity: processStartIdentity,
                  expectedBounds: identity.bounds,
                  isMinimized: !identity.isOnScreen) != nil
        else {
            return nil
        }
        return ExactWindowObservationMetadata(
            ownerProcessIdentifier: identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            title: identity.title,
            bounds: identity.bounds,
            applicationName: identity.applicationName)
    }

    public func windows(for processIdentifier: Int32) -> [SystemWindowIdentity] {
        SystemIdentityResolver.windowIdentities(ownerProcessIdentifier: processIdentifier)
    }

    public func processStartIdentity(for processIdentifier: Int32) -> UInt64? {
        SystemIdentityResolver.processStartIdentity(processIdentifier)
    }
}
