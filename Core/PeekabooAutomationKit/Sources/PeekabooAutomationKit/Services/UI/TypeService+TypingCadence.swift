import Foundation
import PeekabooFoundation

extension TypeService {
    func sleepAfterKeystroke(
        typedCharacter: Character?,
        cadence: TypingCadence,
        fixedDelaySeconds: TimeInterval,
        humanContext: inout HumanTypingContext?) async throws
    {
        let delaySeconds: TimeInterval
        switch cadence {
        case .fixed:
            delaySeconds = fixedDelaySeconds
        case let .human(wordsPerMinute):
            if humanContext == nil {
                humanContext = HumanTypingContext(wordsPerMinute: wordsPerMinute, random: self.cadenceRandom)
            }
            delaySeconds = humanContext?.nextDelay(after: typedCharacter) ?? 0
        }

        guard delaySeconds > 0 else { return }
        try await Task.sleep(for: .seconds(delaySeconds))
    }

    func fixedDelaySeconds(for cadence: TypingCadence) -> TimeInterval {
        if case let .fixed(milliseconds) = cadence {
            return Double(max(0, milliseconds)) / 1000.0
        }
        return 0
    }
}

extension TypingCadence {
    var logDescription: String {
        switch self {
        case let .fixed(milliseconds):
            "fixed(\(milliseconds)ms)"
        case let .human(wordsPerMinute):
            "human(\(wordsPerMinute) WPM)"
        }
    }
}

protocol TypingCadenceRandomSource: Sendable {
    func nextUnitInterval() -> Double
}

struct SystemTypingCadenceRandomSource: TypingCadenceRandomSource {
    func nextUnitInterval() -> Double {
        Double.random(in: Double.leastNonzeroMagnitude..<1.0)
    }
}

struct HumanTypingContext {
    private enum Constants {
        static let logNormalSigma: Double = 0.35
        static let punctuationMultiplier: Double = 1.35
        static let digraphMultiplier: Double = 0.85
        static let thinkingWordInterval: Int = 12
        static let thinkingPauseRange: ClosedRange<Double> = 0.3...0.5
    }

    let baseDelay: TimeInterval
    let random: any TypingCadenceRandomSource
    var previousCharacter: Character?
    var charactersInCurrentWord = 0
    var wordsSincePause = 0

    init(wordsPerMinute: Int, random: any TypingCadenceRandomSource) {
        let normalizedWPM = max(wordsPerMinute, 40)
        self.baseDelay = 60.0 / (Double(normalizedWPM) * 5.0)
        self.random = random
    }

    mutating func nextDelay(after character: Character?) -> TimeInterval {
        var delay = self.sampleLogNormal()

        if let character {
            if character.isWhitespaceLike || character.isPunctuationLike {
                delay *= Constants.punctuationMultiplier
            }

            if let previous = self.previousCharacter,
               previous.isWordCharacter,
               character.isWordCharacter
            {
                delay *= Constants.digraphMultiplier
            }
        }

        delay = self.clamp(delay)

        if let pause = self.consumeWordBoundary(after: character) {
            delay += pause
        }

        self.previousCharacter = character
        return delay
    }

    private mutating func consumeWordBoundary(after character: Character?) -> TimeInterval? {
        guard let character else { return nil }

        if character.isWordCharacter {
            self.charactersInCurrentWord += 1
            return nil
        }

        if self.charactersInCurrentWord == 0 {
            return nil
        }

        self.charactersInCurrentWord = 0
        self.wordsSincePause += 1

        if self.wordsSincePause >= Constants.thinkingWordInterval {
            self.wordsSincePause = 0
            return self.randomThinkingPause()
        }

        return nil
    }

    private mutating func sampleLogNormal() -> TimeInterval {
        let sigma = Constants.logNormalSigma
        let mu = log(self.baseDelay) - 0.5 * sigma * sigma
        let gaussian = Self.generateGaussian(using: self.random)
        let value = exp(mu + sigma * gaussian)
        return max(value, self.baseDelay * 0.2)
    }

    private func clamp(_ value: TimeInterval) -> TimeInterval {
        let minValue = self.baseDelay * 0.25
        let maxValue = self.baseDelay * 3.5
        return min(max(value, minValue), maxValue)
    }

    private func randomThinkingPause() -> TimeInterval {
        let span = Constants.thinkingPauseRange.upperBound - Constants.thinkingPauseRange.lowerBound
        return Constants.thinkingPauseRange.lowerBound + span * self.random.nextUnitInterval()
    }

    private static func generateGaussian(using random: any TypingCadenceRandomSource) -> Double {
        let u1 = max(random.nextUnitInterval(), Double.leastNonzeroMagnitude)
        let u2 = random.nextUnitInterval()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}

extension Character {
    fileprivate var isPunctuationLike: Bool {
        self.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    fileprivate var isWordCharacter: Bool {
        self.isLetter || self.isNumber
    }

    fileprivate var isWhitespaceLike: Bool {
        self.isWhitespace || self == "\n" || self == "\t"
    }
}
