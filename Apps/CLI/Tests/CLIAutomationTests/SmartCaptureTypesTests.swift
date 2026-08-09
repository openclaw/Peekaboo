//
//  SmartCaptureTypesTests.swift
//  CLIAutomationTests
//
//  Tests for SmartCaptureResult and related types.
//

import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomation

struct SmartCaptureResultTests {
    @Test
    func `Fresh capture result indicates change`() {
        let now = Date()
        let result = SmartCaptureResult(
            image: nil,
            changed: true,
            metadata: .fresh(capturedAt: now)
        )

        #expect(result.changed == true)
        if case let .fresh(capturedAt) = result.metadata {
            #expect(capturedAt == now)
        } else {
            Issue.record("Expected fresh metadata")
        }
    }

    @Test
    func `Unchanged capture result indicates no change`() {
        let since = Date()
        let result = SmartCaptureResult(
            image: nil,
            changed: false,
            metadata: .unchanged(since: since)
        )

        #expect(result.changed == false)
        #expect(result.image == nil)
        if case let .unchanged(sinceDate) = result.metadata {
            #expect(sinceDate == since)
        } else {
            Issue.record("Expected unchanged metadata")
        }
    }

    @Test
    func `Region capture includes bounds`() {
        let center = CGPoint(x: 500, y: 300)
        let radius: CGFloat = 200
        let bounds = CGRect(x: 300, y: 100, width: 400, height: 400)

        let result = SmartCaptureResult(
            image: nil,
            changed: true,
            metadata: .region(center: center, radius: radius, bounds: bounds, contextThumbnail: nil)
        )

        #expect(result.changed == true)
        if case let .region(c, r, b, _) = result.metadata {
            #expect(c == center)
            #expect(r == radius)
            #expect(b == bounds)
        } else {
            Issue.record("Expected region metadata")
        }
    }
}

struct SmartCaptureErrorTests {
    @Test
    func `Image conversion error has description`() {
        let error = SmartCaptureError.imageConversionFailed

        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("CGImage") == true)
    }
}
