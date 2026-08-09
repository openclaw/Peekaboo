//
//  UIServiceProtocols.swift
//  PeekabooProtocols
//

import CoreGraphics
import PeekabooFoundation

public struct DetectedElement: Sendable, Codable {
    public let id: String
    public let type: ElementType
    public let bounds: CGRect
    public let label: String?
    public let value: String?
    public let isEnabled: Bool

    public init(
        id: String,
        type: ElementType,
        bounds: CGRect,
        label: String? = nil,
        value: String? = nil,
        isEnabled: Bool = true)
    {
        self.id = id
        self.type = type
        self.bounds = bounds
        self.label = label
        self.value = value
        self.isEnabled = isEnabled
    }
}
