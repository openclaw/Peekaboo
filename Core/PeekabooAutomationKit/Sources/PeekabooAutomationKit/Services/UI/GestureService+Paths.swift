import CoreGraphics
import Foundation
import PeekabooFoundation

extension GestureService {
    func linearPath(from start: CGPoint, to end: CGPoint, steps: Int) -> [CGPoint] {
        guard steps > 1 else { return [end] }
        return (1...steps).map { step in
            let progress = Double(step) / Double(steps)
            let x = start.x + ((end.x - start.x) * progress)
            let y = start.y + ((end.y - start.y) * progress)
            return CGPoint(x: x, y: y)
        }
    }

    func buildGesturePath(
        from start: CGPoint,
        to end: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) -> HumanMousePath
    {
        let distance = hypot(end.x - start.x, end.y - start.y)
        switch profile {
        case .linear:
            return HumanMousePath(points: self.linearPath(from: start, to: end, steps: steps), duration: duration)
        case let .human(configuration):
            let generator = HumanMousePathGenerator(
                start: start,
                target: end,
                distance: distance,
                duration: duration,
                stepsHint: steps,
                configuration: configuration)
            return generator.generate()
        }
    }
}

extension MouseMovementProfile {
    var logDescription: String {
        switch self {
        case .linear:
            "linear"
        case .human:
            "human"
        }
    }
}

struct HumanMousePath {
    let points: [CGPoint]
    let duration: Int
}

struct HumanMousePathGenerator {
    let start: CGPoint
    let target: CGPoint
    let distance: CGFloat
    let duration: Int
    let stepsHint: Int
    let configuration: HumanMouseProfileConfiguration

    func generate() -> HumanMousePath {
        var rng = HumanMouseRandom(seed: self.configuration.randomSeed)
        let sampleCount = min(max(self.stepsHint, 1), 96)
        guard self.distance > 0.5, sampleCount > 1 else {
            return HumanMousePath(points: [self.target], duration: self.duration)
        }

        let delta = CGVector(dx: self.target.x - self.start.x, dy: self.target.y - self.start.y)
        let direction = CGVector(dx: delta.dx / self.distance, dy: delta.dy / self.distance)
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let curveDirection: CGFloat = rng.nextSignedUnit() < 0 ? -1 : 1
        let curveMagnitude = min(self.distance * 0.10, 42)
            * CGFloat(rng.nextDouble(in: 0.55...1.0))
            * curveDirection

        let control1 = CGPoint(
            x: self.start.x + (delta.dx * 0.28) + (normal.dx * curveMagnitude),
            y: self.start.y + (delta.dy * 0.28) + (normal.dy * curveMagnitude))

        let shouldOvershoot = Self.shouldOvershoot(
            distance: self.distance,
            probability: self.configuration.overshootProbability,
            rng: &rng)
        let overshootDistance = shouldOvershoot
            ? self.distance * CGFloat(rng.nextDouble(in: self.configuration.overshootFractionRange))
            : 0
        let control2 = CGPoint(
            x: self.target.x + (direction.dx * overshootDistance) - (normal.dx * curveMagnitude * 0.22),
            y: self.target.y + (direction.dy * overshootDistance) - (normal.dy * curveMagnitude * 0.22))

        var samples: [CGPoint] = []
        samples.reserveCapacity(sampleCount)
        for index in 1...sampleCount {
            let time = CGFloat(index) / CGFloat(sampleCount)
            let progress = Self.minimumJerkProgress(time)
            var point = Self.cubicBezier(
                from: self.start,
                control1: control1,
                control2: control2,
                to: self.target,
                progress: progress)

            if index < sampleCount {
                let distanceRemaining = self.distance * (1 - progress)
                let settleTaper = min(1, distanceRemaining / max(self.configuration.settleRadius, 0.001))
                let jitter = CGFloat(rng.nextSignedUnit())
                    * self.configuration.jitterAmplitude
                    * CGFloat(sin(Double.pi * Double(progress)))
                    * settleTaper
                point.x += normal.dx * jitter
                point.y += normal.dy * jitter
            }
            samples.append(point)
        }

        // Preserve exact targeting even with floating-point interpolation and jitter.
        samples[samples.count - 1] = self.target
        return HumanMousePath(points: samples, duration: self.duration)
    }

    private static func shouldOvershoot(
        distance: CGFloat,
        probability: Double,
        rng: inout HumanMouseRandom) -> Bool
    {
        guard distance > 120 else { return false }
        return rng.nextDouble() < probability
    }

    private static func minimumJerkProgress(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        return (10 * pow(t, 3)) - (15 * pow(t, 4)) + (6 * pow(t, 5))
    }

    private static func cubicBezier(
        from start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        to end: CGPoint,
        progress: CGFloat) -> CGPoint
    {
        let inverse = 1 - progress
        let startWeight = pow(inverse, 3)
        let control1Weight = 3 * pow(inverse, 2) * progress
        let control2Weight = 3 * inverse * pow(progress, 2)
        let endWeight = pow(progress, 3)
        return CGPoint(
            x: (start.x * startWeight) + (control1.x * control1Weight) +
                (control2.x * control2Weight) + (end.x * endWeight),
            y: (start.y * startWeight) + (control1.y * control1Weight) +
                (control2.y * control2Weight) + (end.y * endWeight))
    }
}

private struct HumanMouseRandom: RandomNumberGenerator {
    private var generator: SeededGenerator

    init(seed: UInt64?) {
        let resolvedSeed = seed ?? UInt64(Date().timeIntervalSinceReferenceDate * 1_000_000)
        self.generator = SeededGenerator(seed: resolvedSeed)
    }

    mutating func next() -> UInt64 {
        self.generator.next()
    }

    mutating func nextDouble() -> Double {
        Double(self.next()) / Double(UInt64.max)
    }

    mutating func nextSignedUnit() -> Double {
        (self.nextDouble() * 2) - 1
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let value = self.nextDouble()
        return (value * (range.upperBound - range.lowerBound)) + range.lowerBound
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x123_4567_89AB_CDEF : seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
