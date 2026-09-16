import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

struct DetachedExactWindowFocusSelectionTests {
    private let expectedFrame = CGRect(x: 100, y: 100, width: 200, height: 30)
    private let siblingFrame = CGRect(x: 100, y: 200, width: 200, height: 30)
    private let reflowedFrame = CGRect(x: 100, y: 100, width: 200, height: 60)

    @Test
    func `single candidate is selected for downstream focus confirmation`() {
        let selected = DetachedExactWindowFocusReader.selectContinuationReceiver(
            candidateFrames: [self.reflowedFrame],
            candidateFocused: [false],
            expectedFrame: self.expectedFrame)

        #expect(selected == 0)
    }

    @Test
    func `unchanged receiver among duplicate labels is selected by exact frame`() {
        let selected = DetachedExactWindowFocusReader.selectContinuationReceiver(
            candidateFrames: [self.siblingFrame, self.expectedFrame],
            candidateFocused: [false, true],
            expectedFrame: self.expectedFrame)

        #expect(selected == 1)
    }

    @Test
    func `reflowed receiver is selected by unique focus`() {
        let selected = DetachedExactWindowFocusReader.selectContinuationReceiver(
            candidateFrames: [self.siblingFrame, self.reflowedFrame],
            candidateFocused: [false, true],
            expectedFrame: self.expectedFrame)

        #expect(selected == 1)
    }

    @Test
    func `reflow without focused candidate is ambiguous`() {
        let selected = DetachedExactWindowFocusReader.selectContinuationReceiver(
            candidateFrames: [self.siblingFrame, self.reflowedFrame],
            candidateFocused: [false, false],
            expectedFrame: self.expectedFrame)

        #expect(selected == nil)
    }

    @Test
    func `reflow with multiple focused candidates is ambiguous`() {
        let selected = DetachedExactWindowFocusReader.selectContinuationReceiver(
            candidateFrames: [self.siblingFrame, self.reflowedFrame],
            candidateFocused: [true, true],
            expectedFrame: self.expectedFrame)

        #expect(selected == nil)
    }

    @Test
    func `exact frame takes precedence over focused sibling`() {
        let selected = DetachedExactWindowFocusReader.selectContinuationReceiver(
            candidateFrames: [self.expectedFrame, self.siblingFrame],
            candidateFocused: [false, true],
            expectedFrame: self.expectedFrame)

        #expect(selected == 0)
    }

    @Test
    func `duplicate exact frames fall back to unique focus`() {
        let selected = DetachedExactWindowFocusReader.selectContinuationReceiver(
            candidateFrames: [self.expectedFrame, self.expectedFrame],
            candidateFocused: [false, true],
            expectedFrame: self.expectedFrame)

        #expect(selected == 1)
    }

    @Test
    func `empty or mismatched candidates have no selection`() {
        #expect(DetachedExactWindowFocusReader.selectContinuationReceiver(
            candidateFrames: [],
            candidateFocused: [],
            expectedFrame: self.expectedFrame) == nil)
        #expect(DetachedExactWindowFocusReader.selectContinuationReceiver(
            candidateFrames: [self.expectedFrame, self.siblingFrame],
            candidateFocused: [true],
            expectedFrame: self.expectedFrame) == nil)
    }
}
