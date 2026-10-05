import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeTypeActionCountTests {
    private enum Step: Sendable {
        case clear
        case text(String)
        case space
        case optionalKey(SpecialKey)
        case returnKey

        var action: TypeAction {
            switch self {
            case .clear: .clear
            case let .text(text): .text(text)
            case .space: .key(.space)
            case let .optionalKey(key): .key(key)
            case .returnKey: .key(.return)
            }
        }

        var deliveries: [Counts] {
            switch self {
            case .clear: [.zero, .ax, .init(units: 2, keys: 2, special: 2, keyboard: true)]
            case .text: [.ax, .textKey]
            case .space: [.ax, .specialKey]
            case .optionalKey: [.zero, .ax, .specialKey]
            case .returnKey: [.specialKey]
            }
        }
    }

    private struct Counts: Hashable, Sendable {
        var units = 0
        var keys = 0
        var special = 0
        var accessibility = false
        var keyboard = false

        static let zero = Self()
        static let ax = Self(units: 1, accessibility: true)
        static let textKey = Self(units: 1, keys: 1, keyboard: true)
        static let specialKey = Self(units: 1, keys: 1, special: 1, keyboard: true)

        func adding(_ other: Self) -> Self {
            Self(
                units: self.units + other.units,
                keys: self.keys + other.keys,
                special: self.special + other.special,
                accessibility: self.accessibility || other.accessibility,
                keyboard: self.keyboard || other.keyboard)
        }
    }

    @Test
    func `no-op clear accounting matches independent per-action enumeration`() {
        let cases: [[Step]] = [
            [.clear], [.clear, .clear], [.clear, .text("x")], [.clear, .text("e\u{301}👩🏽‍💻")],
            [.clear, .space, .optionalKey(.delete), .clear],
            [.optionalKey(.forwardDelete), .clear, .returnKey],
            [.optionalKey(.leftArrow), .clear, .space],
            [.text("x"), .clear, .clear, .optionalKey(.rightArrow)],
            [.clear, .optionalKey(.home), .optionalKey(.end)],
        ]
        for steps in cases {
            for prefixUnits in 0...1 {
                let rule = PeekabooBridgeOperationResultSemantics.TypeActionResultRule(
                    actions: steps.map(\.action),
                    allowsAccessibilityValueDelivery: true,
                    additionalAccessibilityUnits: prefixUnits)
                let expected = Self.enumerate(steps, prefixUnits: prefixUnits)
                let maximum = (expected.map(\.units).max() ?? 0) + 1
                for units in 0...maximum {
                    for mechanism in Self.mechanisms(for: units) {
                        let outcome: DesktopActionOutcome = if let mechanism {
                            .dispatchedUnverified(
                                delivery: .init(mechanism: mechanism, mode: .background),
                                evidence: .deliveryAccepted,
                                unitCount: .init(units))
                        } else {
                            .confirmedNoChange()
                        }
                        for keys in -1...maximum {
                            for special in [nil] + (-1...maximum).map(Optional.some) {
                                let valid = expected.contains { count in
                                    count.units == units && count.keys == keys &&
                                        (special == nil || count.special == special) &&
                                        count
                                        .accessibility ==
                                        (mechanism == .accessibilityValue || mechanism == .composite) &&
                                        count
                                        .keyboard == (mechanism == .windowTargetedEvents || mechanism == .composite)
                                }
                                #expect(rule.accepts(
                                    keyPresses: keys,
                                    specialKeyPresses: special,
                                    outcome: outcome) == valid)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `no-op caret metadata excludes inserting and committing keys`() {
        for key: SpecialKey in [.delete, .forwardDelete, .leftArrow, .rightArrow, .home, .end] {
            #expect(key.mayUseAccessibilityValueDelivery)
            #expect(key.mayCompleteWithoutDispatch)
        }
        for key: SpecialKey in [.space, .return, .tab, .escape] {
            #expect(!key.mayCompleteWithoutDispatch)
        }
    }

    @Test
    func `inserting and committing actions cannot claim a zero-dispatch success`() {
        for action: TypeAction in [.text("x"), .key(.space), .key(.return)] {
            let rule = PeekabooBridgeOperationResultSemantics.TypeActionResultRule(
                actions: [.clear, action],
                allowsAccessibilityValueDelivery: true)
            for special: Int? in [nil, 0] {
                #expect(!rule.accepts(keyPresses: 0, specialKeyPresses: special, outcome: .confirmedNoChange()))
            }
        }
    }

    @Test
    func `clear accounting rejects extreme forged counts without arithmetic overflow`() {
        let rule = PeekabooBridgeOperationResultSemantics.TypeActionResultRule(
            actions: [.clear, .text("x")],
            allowsAccessibilityValueDelivery: true)
        let counts: [(Int, Int?)] = [(Int.min, nil), (Int.max, nil), (Int.max, Int.min), (Int.max, Int.max)]
        for units in [1, 3, Int.max] {
            let outcome = DesktopActionOutcome.dispatchedUnverified(
                delivery: .init(mechanism: .composite, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(units))
            for (keys, special) in counts {
                #expect(!rule.accepts(keyPresses: keys, specialKeyPresses: special, outcome: outcome))
            }
        }
    }

    @Test
    func `many no-op clears require no dispatch and do not enumerate their subsets`() {
        let rule = PeekabooBridgeOperationResultSemantics.TypeActionResultRule(
            actions: Array(repeating: .clear, count: 10000),
            allowsAccessibilityValueDelivery: true)
        #expect(rule.dispatchUnits == .range(0...20000))
        for special: Int? in [nil, 0] {
            #expect(rule.accepts(keyPresses: 0, specialKeyPresses: special, outcome: .confirmedNoChange()))
            #expect(!rule.accepts(keyPresses: 1, specialKeyPresses: special, outcome: .confirmedNoChange()))
        }
    }

    private static func enumerate(_ steps: [Step], prefixUnits: Int) -> Set<Counts> {
        var counts: Set<Counts> = [prefixUnits == 0 ? .zero : .ax]
        for step in steps {
            let repetitions = if case let .text(text) = step {
                text.count
            } else {
                1
            }
            for _ in 0..<repetitions {
                counts = Set(counts.flatMap { total in step.deliveries.map { total.adding($0) } })
            }
        }
        return counts
    }

    private static func mechanisms(for units: Int) -> [DesktopActionOutcome.Delivery.Mechanism?] {
        units == 0 ? [nil] : [.accessibilityValue, .windowTargetedEvents, .composite]
    }
}
