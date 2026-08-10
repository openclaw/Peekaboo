import CoreGraphics
import MCP
import PeekabooAutomationKit

enum CaptureCoordinateContextMetadata {
    static func value(for metadata: CaptureMetadata, referenceID: String? = nil) -> Value {
        self.value(for: CaptureCoordinateContext(metadata: metadata, referenceID: referenceID))
    }

    static func value(for context: CaptureCoordinateContext) -> Value {
        var payload: [String: Value] = [
            "version": .int(context.version),
            "reference_id": context.referenceID.map(Value.string) ?? .null,
            "logical_space": .string(context.logicalSpace.rawValue),
            "origin": .string(context.origin.rawValue),
            "logical_bounds": context.logicalBounds.map(self.rectValue) ?? .null,
            "delivered_image_size": self.sizeValue(context.deliveredImageSize),
            "requested_scale": context.requestedScale.map { .string(self.scaleName($0)) } ?? .null,
            "native_scale": context.nativeScale.map { .double(Double($0)) } ?? .null,
            "output_scale": context.outputScale.map { .double(Double($0)) } ?? .null,
        ]

        payload["display"] = context.display.map { display in
            .object([
                "index": .int(display.index),
                "name": display.name.map(Value.string) ?? .null,
            ])
        } ?? .null
        payload["window"] = context.window.map { window in
            .object([
                "window_id": .int(window.windowID),
                "title": .string(window.title),
                "index": .int(window.index),
                "screen_index": window.screenIndex.map(Value.int) ?? .null,
                "screen_name": window.screenName.map(Value.string) ?? .null,
            ])
        } ?? .null
        payload["viewport"] = context.viewport.map { viewport in
            .object([
                "source_logical_bounds": self.rectValue(viewport.sourceLogicalBounds),
                "requested_window_relative_bounds": self.rectValue(viewport.requestedWindowRelativeBounds),
                "delivered_window_relative_bounds": self.rectValue(viewport.deliveredWindowRelativeBounds),
                "logical_bounds": self.rectValue(viewport.logicalBounds),
                "source_image_size": self.sizeValue(viewport.sourceImageSize),
            ])
        } ?? .null

        return .object(payload)
    }

    private static func scaleName(_ scale: CaptureScalePreference) -> String {
        switch scale {
        case .logical1x: "logical1x"
        case .native: "native"
        }
    }

    static func rectValue(_ rect: CGRect) -> Value {
        .object([
            "x": .double(Double(rect.origin.x)),
            "y": .double(Double(rect.origin.y)),
            "width": .double(Double(rect.width)),
            "height": .double(Double(rect.height)),
        ])
    }

    static func sizeValue(_ size: CGSize) -> Value {
        .object([
            "width": .double(Double(size.width)),
            "height": .double(Double(size.height)),
        ])
    }
}
