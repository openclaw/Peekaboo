import Darwin
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct DarwinProcessLoopbackListenerInspectorTests {
    @Test
    func `one complete loopback listener binds to the expected process generation`() throws {
        let identity = try DarwinProcessLoopbackListenerInspector.inspect(
            processIdentifier: 71,
            processStartIdentity: 9071,
            port: 9222,
            source: Self.source(sockets: [Self.socket()]))

        #expect(identity.processIdentifier == 71)
        #expect(identity.processStartIdentity == 9071)
        #expect(identity.addressFamily == .ipv4)
        #expect(identity.port == 9222)
        #expect(identity.kernelGeneration == 3)
    }

    @Test
    func `PID reuse before or after descriptor inspection is refused`() {
        for generations: [UInt64] in [[9073], [9072, 9073]] {
            let box = ValuesBox(generations)
            let source = Self.source(
                sockets: [Self.socket()],
                processStartIdentity: { _ in box.next() })

            #expect(throws: DarwinProcessLoopbackListenerInspectionError.processGenerationChanged(72)) {
                _ = try DarwinProcessLoopbackListenerInspector.inspect(
                    processIdentifier: 72,
                    processStartIdentity: 9072,
                    port: 9222,
                    source: source)
            }
        }
    }

    @Test
    func `full inventory at the descriptor ceiling is treated as truncated`() {
        let source = DarwinProcessLoopbackListenerInspector.InspectionSource(
            processStartIdentity: { _ in 9073 },
            descriptorCapacityBounds: { _ in .init(initial: 64, limit: 64) },
            listDescriptors: { _, capacity in
                .init(descriptors: [], filledBuffer: capacity == 64, hasPartialRecord: false)
            },
            socketObservation: { _, _ in nil })

        #expect(throws: DarwinProcessLoopbackListenerInspectionError.descriptorInventoryTruncated(73)) {
            _ = try DarwinProcessLoopbackListenerInspector.inspect(
                processIdentifier: 73,
                processStartIdentity: 9073,
                port: 9222,
                source: source)
        }
    }

    @Test
    func `descriptor inventory grows beyond the inspector file descriptor limit`() throws {
        let capacities = CapacityBox()
        let observedDescriptor = DescriptorBox()
        let source = DarwinProcessLoopbackListenerInspector.InspectionSource(
            processStartIdentity: { _ in 9076 },
            descriptorCapacityBounds: { _ in .init(initial: 64, limit: 512) },
            listDescriptors: { _, capacity in
                capacities.append(capacity)
                if capacity < 512 {
                    return .init(descriptors: [], filledBuffer: true, hasPartialRecord: false)
                }
                return .init(
                    descriptors: [.init(fileDescriptor: 4096, isSocket: true)],
                    filledBuffer: false,
                    hasPartialRecord: false)
            },
            socketObservation: { _, descriptor in
                observedDescriptor.value = descriptor
                return descriptor == 4096 ? Self.socket() : nil
            })

        let identity = try DarwinProcessLoopbackListenerInspector.inspect(
            processIdentifier: 76,
            processStartIdentity: 9076,
            port: 9222,
            source: source)

        #expect(identity.processIdentifier == 76)
        #expect(capacities.values == [64, 128, 256, 512])
        #expect(observedDescriptor.value == 4096)
    }

    @Test
    func `IPv4 IPv6 split ownership is ambiguous rather than guessed`() {
        let sockets = [
            Self.socket(family: .ipv4, kernelSocketAddress: 1),
            Self.socket(family: .ipv6, kernelSocketAddress: 2),
        ]

        #expect(throws: DarwinProcessLoopbackListenerInspectionError.listenerAmbiguous(74, 9222, count: 2)) {
            _ = try DarwinProcessLoopbackListenerInspector.inspect(
                processIdentifier: 74,
                processStartIdentity: 9074,
                port: 9222,
                source: Self.source(sockets: sockets, generation: 9074))
        }
    }

    @Test
    func `non listening and non loopback sockets cannot authorize DevTools`() {
        #expect(throws: DarwinProcessLoopbackListenerInspectionError.listenerNotFound(75, 9222)) {
            _ = try DarwinProcessLoopbackListenerInspector.inspect(
                processIdentifier: 75,
                processStartIdentity: 9075,
                port: 9222,
                source: Self.source(
                    sockets: [Self.socket(isListening: false)],
                    generation: 9075))
        }

        #expect(throws: DarwinProcessLoopbackListenerInspectionError.listenerNotLoopback(75, 9222)) {
            _ = try DarwinProcessLoopbackListenerInspector.inspect(
                processIdentifier: 75,
                processStartIdentity: 9075,
                port: 9222,
                source: Self.source(
                    sockets: [Self.socket(family: nil)],
                    generation: 9075))
        }

        #expect(throws: DarwinProcessLoopbackListenerInspectionError.listenerAllowsPortReuse(75, 9222)) {
            _ = try DarwinProcessLoopbackListenerInspector.inspect(
                processIdentifier: 75,
                processStartIdentity: 9075,
                port: 9222,
                source: Self.source(
                    sockets: [Self.socket(allowsPortReuse: true)],
                    generation: 9075))
        }
    }

    private static func source(
        sockets: [DarwinProcessLoopbackListenerInspector.SocketObservation],
        generation: UInt64 = 9071,
        processStartIdentity: (@Sendable (pid_t) -> UInt64?)? = nil)
        -> DarwinProcessLoopbackListenerInspector.InspectionSource
    {
        let socketMap = Dictionary(uniqueKeysWithValues: sockets.enumerated().map { offset, socket in
            (Int32(offset + 10), socket)
        })
        return .init(
            processStartIdentity: processStartIdentity ?? { _ in generation },
            descriptorCapacityBounds: { _ in .init(initial: 64, limit: 256) },
            listDescriptors: { _, _ in
                .init(
                    descriptors: socketMap.keys.sorted().map {
                        .init(fileDescriptor: $0, isSocket: true)
                    },
                    filledBuffer: false,
                    hasPartialRecord: false)
            },
            socketObservation: { _, descriptor in socketMap[descriptor] })
    }

    private static func socket(
        isListening: Bool = true,
        family: DarwinLoopbackAddressFamily? = .ipv4,
        allowsPortReuse: Bool = false,
        kernelSocketAddress: UInt64 = 1)
        -> DarwinProcessLoopbackListenerInspector.SocketObservation
    {
        .init(
            isTCPListener: isListening,
            port: 9222,
            loopbackAddressFamily: family,
            allowsPortReuse: allowsPortReuse,
            kernelSocketAddress: kernelSocketAddress,
            kernelProtocolControlBlock: kernelSocketAddress + 1,
            kernelGeneration: kernelSocketAddress + 2)
    }
}

private final class CapacityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Int] = []

    var values: [Int] {
        self.lock.withLock { self.storedValues }
    }

    func append(_ value: Int) {
        self.lock.withLock {
            self.storedValues.append(value)
        }
    }
}

private final class DescriptorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int32?

    var value: Int32? {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }
}

private final class ValuesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(_ values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.values.isEmpty else { return nil }
        return self.values.removeFirst()
    }
}
