import CoreGraphics
import Foundation
import PeekabooAutomationKit

/// Path-free foreground semantic proof carried by one authenticated certification producer.
///
/// The raw values and their three source Bridge bundles travel together. Digests are indexes over
/// those raw values, never standalone authority.
public struct PeekabooBridgeCertificationObserverSemanticPayload: Codable, Equatable, Sendable {
    public struct ObservationInterval: Codable, Equatable, Sendable {
        public let startedAtUnixMilliseconds: Int64
        public let completedAtUnixMilliseconds: Int64

        public init(startedAtUnixMilliseconds: Int64, completedAtUnixMilliseconds: Int64) {
            self.startedAtUnixMilliseconds = startedAtUnixMilliseconds
            self.completedAtUnixMilliseconds = completedAtUnixMilliseconds
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case startedAtUnixMilliseconds
            case completedAtUnixMilliseconds
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Certification semantic observation interval")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.startedAtUnixMilliseconds = try container.decode(
                Int64.self,
                forKey: .startedAtUnixMilliseconds)
            self.completedAtUnixMilliseconds = try container.decode(
                Int64.self,
                forKey: .completedAtUnixMilliseconds)
        }
    }

    public let schemaVersion: Int
    public let target: WindowMutationIdentity
    public let focusedElement: FocusedElementIdentity
    public let observationInterval: ObservationInterval
    public let requestMarker: String
    public let beforeValue: String
    public let expectedValue: String
    public let observedValue: String
    public let restoredValue: String
    public let beforeValueSHA256: String
    public let expectedValueSHA256: String
    public let observedValueSHA256: String
    public let restoredValueSHA256: String
    public let passed: Bool
    public let restored: Bool
    public let readbackBundles: [PeekabooBridgeOperationReceiptBundle]

    public init(
        schemaVersion: Int = 1,
        target: WindowMutationIdentity,
        focusedElement: FocusedElementIdentity,
        observationInterval: ObservationInterval,
        requestMarker: String,
        beforeValue: String,
        expectedValue: String,
        observedValue: String,
        restoredValue: String,
        readbackBundles: [PeekabooBridgeOperationReceiptBundle])
    {
        self.schemaVersion = schemaVersion
        self.target = target
        self.focusedElement = focusedElement
        self.observationInterval = observationInterval
        self.requestMarker = requestMarker
        self.beforeValue = beforeValue
        self.expectedValue = expectedValue
        self.observedValue = observedValue
        self.restoredValue = restoredValue
        self.beforeValueSHA256 = Self.sha256(beforeValue)
        self.expectedValueSHA256 = Self.sha256(expectedValue)
        self.observedValueSHA256 = Self.sha256(observedValue)
        self.restoredValueSHA256 = Self.sha256(restoredValue)
        self.passed = beforeValue != expectedValue && expectedValue == observedValue
        self.restored = beforeValue == restoredValue
        self.readbackBundles = readbackBundles
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case target
        case focusedElement
        case observationInterval
        case requestMarker
        case beforeValue
        case expectedValue
        case observedValue
        case restoredValue
        case beforeValueSHA256
        case expectedValueSHA256
        case observedValueSHA256
        case restoredValueSHA256
        case passed
        case restored
        case readbackBundles
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Certification observer semantic payload")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.target = try container.decode(WindowMutationIdentity.self, forKey: .target)
        self.focusedElement = try container.decode(FocusedElementIdentity.self, forKey: .focusedElement)
        self.observationInterval = try container.decode(
            ObservationInterval.self,
            forKey: .observationInterval)
        self.requestMarker = try container.decode(String.self, forKey: .requestMarker)
        self.beforeValue = try container.decode(String.self, forKey: .beforeValue)
        self.expectedValue = try container.decode(String.self, forKey: .expectedValue)
        self.observedValue = try container.decode(String.self, forKey: .observedValue)
        self.restoredValue = try container.decode(String.self, forKey: .restoredValue)
        self.beforeValueSHA256 = try container.decode(String.self, forKey: .beforeValueSHA256)
        self.expectedValueSHA256 = try container.decode(String.self, forKey: .expectedValueSHA256)
        self.observedValueSHA256 = try container.decode(String.self, forKey: .observedValueSHA256)
        self.restoredValueSHA256 = try container.decode(String.self, forKey: .restoredValueSHA256)
        self.passed = try container.decode(Bool.self, forKey: .passed)
        self.restored = try container.decode(Bool.self, forKey: .restored)
        self.readbackBundles = try container.decode(
            [PeekabooBridgeOperationReceiptBundle].self,
            forKey: .readbackBundles)
    }

    func validate(context: PeekabooBridgeCertificationPayloadValidationContext) throws {
        guard context.request.kind == .observerSemantic,
              self.schemaVersion == 1,
              self.readbackBundles.count == 3,
              Self.validTarget(self.target),
              Self.validFocusedElement(self.focusedElement, target: self.target),
              PeekabooBridgeCertificationValidation.isSafeIdentifier(
                  self.requestMarker,
                  maximumBytes: 4096),
              Self.validValue(self.beforeValue),
              Self.validValue(self.expectedValue),
              Self.validValue(self.observedValue),
              Self.validValue(self.restoredValue)
        else {
            throw Self.invalid("closed witness fields")
        }

        let producer = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: context.producer.processIdentifier,
            processStartIdentity: context.producer.processStartIdentity,
            codeSignatureHash: context.producer.codeSignatureHash)
        guard context.request.expectedProducer.processIdentifier == producer.processIdentifier,
              context.request.expectedProducer.processStartIdentity == producer.processStartIdentity,
              context.request.expectedProducer.codeSignatureHash == producer.codeSignatureHash,
              context.producer.signingIdentifier ==
              PeekabooBridgeCertificationProducerAttestationKind.observerSemantic.expectedSigningIdentifier,
              context.producer.teamIdentifier == PeekabooBridgeCertificationValidation.foundationTeamIdentifier
        else {
            throw Self.invalid("authenticated producer")
        }

        do {
            try context.listenerAttestation.validateSignature()
        } catch {
            throw Self.invalid("listener attestation")
        }

        let readbacks = try self.readbackBundles.enumerated().map { index, bundle in
            try self.readback(
                bundle,
                index: index,
                producer: producer,
                listenerAttestation: context.listenerAttestation)
        }
        guard let session = self.readbackBundles.first?.operationSessionAttestation,
              self.readbackBundles.allSatisfy({ $0.operationSessionAttestation == session }),
              session.client == producer,
              readbacks[0].sequence < UInt64.max - 1,
              readbacks[1].sequence == readbacks[0].sequence + 1,
              readbacks[2].sequence == readbacks[1].sequence + 1
        else {
            throw Self.invalid("single consecutive producer session")
        }

        let baseline = readbacks[0]
        let observed = readbacks[1]
        let restored = readbacks[2]
        let expectedRequestMarker = "peekaboo-foreground-postcondition:\(context.request.executionNonce)"
        guard baseline.completedAtUnixMilliseconds <= observed.startedAtUnixMilliseconds,
              observed.completedAtUnixMilliseconds <= restored.startedAtUnixMilliseconds,
              self.observationInterval.startedAtUnixMilliseconds == observed.startedAtUnixMilliseconds,
              self.observationInterval.completedAtUnixMilliseconds == observed.completedAtUnixMilliseconds,
              Self.sameElement(baseline.focus, observed.focus),
              Self.sameElement(observed.focus, restored.focus),
              FocusedElementIdentity(baseline.focus) == self.focusedElement,
              baseline.value == self.beforeValue,
              observed.value == self.observedValue,
              restored.value == self.restoredValue,
              self.requestMarker == expectedRequestMarker,
              self.expectedValue == expectedRequestMarker,
              self.observedValue == self.expectedValue,
              self.restoredValue == self.beforeValue,
              self.beforeValue != self.expectedValue,
              self.beforeValueSHA256 == Self.sha256(self.beforeValue),
              self.expectedValueSHA256 == Self.sha256(self.expectedValue),
              self.observedValueSHA256 == Self.sha256(self.observedValue),
              self.restoredValueSHA256 == Self.sha256(self.restoredValue),
              self.expectedValueSHA256 == self.observedValueSHA256,
              self.beforeValueSHA256 == self.restoredValueSHA256,
              self.passed,
              self.restored
        else {
            throw Self.invalid("value, digest, timing, or restoration semantics")
        }
    }

    private struct Readback {
        let sequence: UInt64
        let startedAtUnixMilliseconds: Int64
        let completedAtUnixMilliseconds: Int64
        let focus: UIFocusInfo
        let value: String
    }

    private func readback(
        _ bundle: PeekabooBridgeOperationReceiptBundle,
        index: Int,
        producer: PeekabooBridgeOperationProcessIdentity,
        listenerAttestation: PeekabooBridgeListenerAttestation) throws -> Readback
    {
        do {
            try bundle.validate(trustAnchor: .listenerAttestation(listenerAttestation))
        } catch {
            throw Self.invalid("readback bundle \(index) listener or signature")
        }
        let payload = bundle.receipt.payload
        guard bundle.operationAttestation == listenerAttestation,
              bundle.operationSessionAttestation.client == producer,
              payload.client == producer,
              payload.clientInstanceID == bundle.operationSessionAttestation.clientInstanceID,
              payload.listenerInstanceID == listenerAttestation.listenerInstanceID,
              payload.operation == .getFocusedElement,
              payload.outcome == nil,
              payload.focusedElement == nil,
              payload.targetAttributionFailure == nil,
              payload.targetAttributionEvidence == nil,
              payload.selectedLeafEvidence == nil,
              PeekabooBridgeCertificationValidation.isPositiveSafeInteger(
                  payload.startedAtUnixMilliseconds),
              payload.completedAtUnixMilliseconds >= payload.startedAtUnixMilliseconds,
              payload.completedAtUnixMilliseconds <= PeekabooBridgeCertificationValidation.maximumSafeInteger,
              case let .process(targetProcess) = payload.target,
              targetProcess == self.target.processIdentity
        else {
            throw Self.invalid("readback bundle \(index) authority or target")
        }

        let request: PeekabooBridgeRequest
        let response: PeekabooBridgeResponse
        do {
            request = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeRequest.self,
                from: bundle.canonicalRequest)
            response = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: bundle.canonicalResponse)
        } catch {
            throw Self.invalid("readback bundle \(index) canonical request or response")
        }
        guard case let .getFocusedElement(focusedRequest) = request,
              focusedRequest.targetProcessIdentifier == self.target.ownerProcessIdentifier,
              focusedRequest.expectedProcessIdentity == self.target.processIdentity,
              case let .focusedElement(focus?) = response,
              let identity = FocusedElementIdentity(focus),
              identity == self.focusedElement,
              focus.processId == Int(self.target.ownerProcessIdentifier),
              focus.windowID == self.target.windowID,
              let value = focus.value,
              Self.validValue(value)
        else {
            throw Self.invalid("readback bundle \(index) exact focused element")
        }
        return Readback(
            sequence: payload.sessionSequence.value,
            startedAtUnixMilliseconds: payload.startedAtUnixMilliseconds,
            completedAtUnixMilliseconds: payload.completedAtUnixMilliseconds,
            focus: focus,
            value: value)
    }

    private static func validTarget(_ target: WindowMutationIdentity) -> Bool {
        guard target.windowID > 0,
              UInt32(exactly: target.windowID) != nil,
              target.ownerProcessIdentifier > 0,
              target.ownerProcessStartIdentity > 0,
              target.isMinimized == false,
              let bounds = target.capturedBounds
        else { return false }
        return Self.validRectangle(bounds)
    }

    private static func validFocusedElement(
        _ focusedElement: FocusedElementIdentity,
        target: WindowMutationIdentity) -> Bool
    {
        guard focusedElement.processIdentifier == target.ownerProcessIdentifier,
              focusedElement.windowID == target.windowID,
              PeekabooBridgeCertificationValidation.isSafeIdentifier(
                  focusedElement.role,
                  maximumBytes: 256),
              focusedElement.identifier != nil || focusedElement.title != nil,
              focusedElement.identifier.map({
                  PeekabooBridgeCertificationValidation.isSafeIdentifier($0, maximumBytes: 1024)
              }) ?? true,
              focusedElement.title.map({
                  PeekabooBridgeCertificationValidation.isSafeIdentifier($0, maximumBytes: 1024)
              }) ?? true,
              self.validRectangle(focusedElement.frame),
              let bounds = target.capturedBounds
        else { return false }
        return bounds.contains(focusedElement.frame)
    }

    private static func validRectangle(_ rectangle: CGRect) -> Bool {
        rectangle.origin.x.isFinite &&
            rectangle.origin.y.isFinite &&
            rectangle.width.isFinite &&
            rectangle.height.isFinite &&
            rectangle.width > 0 &&
            rectangle.height > 0
    }

    private static func validValue(_ value: String) -> Bool {
        value.utf8.count <= 256 * 1024 && !value.contains("\0")
    }

    private static func sameElement(_ lhs: UIFocusInfo, _ rhs: UIFocusInfo) -> Bool {
        FocusedElementIdentity(lhs) == FocusedElementIdentity(rhs) &&
            lhs.applicationName == rhs.applicationName &&
            lhs.bundleIdentifier == rhs.bundleIdentifier &&
            !lhs.applicationName.isEmpty &&
            !lhs.bundleIdentifier.isEmpty
    }

    private static func sha256(_ value: String) -> String {
        PeekabooBridgeOperationReceiptCoding.sha256(Data(value.utf8))
    }

    private static func invalid(_ field: String) -> PeekabooBridgeOperationReceiptError {
        .receiptMismatch("certification observer semantic \(field)")
    }
}
