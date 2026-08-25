import Darwin
import Foundation

public enum DarwinLoopbackAddressFamily: String, Sendable, Hashable {
    case ipv4
    case ipv6

    public var httpHost: String {
        switch self {
        case .ipv4: "127.0.0.1"
        case .ipv6: "[::1]"
        }
    }
}

public struct DarwinProcessLoopbackListenerIdentity: Sendable, Hashable {
    public let processIdentifier: pid_t
    public let processStartIdentity: UInt64
    public let addressFamily: DarwinLoopbackAddressFamily
    public let port: UInt16
    public let kernelSocketAddress: UInt64
    public let kernelProtocolControlBlock: UInt64
    public let kernelGeneration: UInt64

    public init(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        addressFamily: DarwinLoopbackAddressFamily,
        port: UInt16,
        kernelSocketAddress: UInt64,
        kernelProtocolControlBlock: UInt64,
        kernelGeneration: UInt64)
    {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.addressFamily = addressFamily
        self.port = port
        self.kernelSocketAddress = kernelSocketAddress
        self.kernelProtocolControlBlock = kernelProtocolControlBlock
        self.kernelGeneration = kernelGeneration
    }
}

public enum DarwinProcessLoopbackListenerInspectionError: LocalizedError, Equatable, Sendable {
    case invalidProcess
    case processGenerationChanged(pid_t)
    case descriptorInventoryUnavailable(pid_t)
    case descriptorInventoryTruncated(pid_t)
    case socketInventoryIncomplete(pid_t)
    case listenerNotFound(pid_t, UInt16)
    case listenerNotLoopback(pid_t, UInt16)
    case listenerAllowsPortReuse(pid_t, UInt16)
    case listenerAmbiguous(pid_t, UInt16, count: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidProcess:
            "A positive process identifier and generation are required."
        case let .processGenerationChanged(processIdentifier):
            "PID \(processIdentifier) changed generation during listener inspection."
        case let .descriptorInventoryUnavailable(processIdentifier):
            "The socket descriptor inventory for PID \(processIdentifier) is unavailable."
        case let .descriptorInventoryTruncated(processIdentifier):
            "The socket descriptor inventory for PID \(processIdentifier) was truncated."
        case let .socketInventoryIncomplete(processIdentifier):
            "The socket inventory for PID \(processIdentifier) was incomplete."
        case let .listenerNotFound(processIdentifier, port):
            "PID \(processIdentifier) does not own a TCP listener on port \(port)."
        case let .listenerNotLoopback(processIdentifier, port):
            "PID \(processIdentifier)'s TCP listener on port \(port) is not bound to an exact loopback address."
        case let .listenerAllowsPortReuse(processIdentifier, port):
            "PID \(processIdentifier)'s TCP listener on port \(port) permits shared port ownership."
        case let .listenerAmbiguous(processIdentifier, port, count):
            "PID \(processIdentifier) owns \(count) TCP listeners on port \(port); " +
                "one exact loopback listener is required."
        }
    }
}

/// Exhaustive, generation-bound inspection of one process's TCP listeners.
///
/// A full descriptor buffer is treated as truncated and rescanned at a larger capacity. Any socket
/// that cannot be inspected makes the result indeterminate rather than allowing a hidden listener.
public struct DarwinProcessLoopbackListenerInspector: Sendable {
    public typealias Inspect = @Sendable (
        _ processIdentifier: pid_t,
        _ processStartIdentity: UInt64,
        _ port: UInt16) throws -> DarwinProcessLoopbackListenerIdentity

    public let inspect: Inspect

    public init(inspect: @escaping Inspect) {
        self.inspect = inspect
    }

    public static let live = DarwinProcessLoopbackListenerInspector { processIdentifier, generation, port in
        try Self.inspect(
            processIdentifier: processIdentifier,
            processStartIdentity: generation,
            port: port,
            source: .live)
    }

    static func inspect(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        port: UInt16,
        source: InspectionSource) throws -> DarwinProcessLoopbackListenerIdentity
    {
        guard processIdentifier > 0, processStartIdentity > 0 else {
            throw DarwinProcessLoopbackListenerInspectionError.invalidProcess
        }
        guard source.processStartIdentity(processIdentifier) == processStartIdentity else {
            throw DarwinProcessLoopbackListenerInspectionError.processGenerationChanged(processIdentifier)
        }

        let initialCapacity = 64
        let capacityLimit = max(initialCapacity, source.descriptorCapacityLimit())
        var capacity = min(initialCapacity, capacityLimit)
        let descriptors: [Descriptor]
        while true {
            guard let batch = source.listDescriptors(processIdentifier, capacity) else {
                throw DarwinProcessLoopbackListenerInspectionError
                    .descriptorInventoryUnavailable(processIdentifier)
            }
            guard !batch.hasPartialRecord else {
                throw DarwinProcessLoopbackListenerInspectionError
                    .descriptorInventoryTruncated(processIdentifier)
            }
            if batch.filledBuffer {
                guard capacity < capacityLimit else {
                    throw DarwinProcessLoopbackListenerInspectionError
                        .descriptorInventoryTruncated(processIdentifier)
                }
                capacity = min(capacity * 2, capacityLimit)
                continue
            }
            descriptors = batch.descriptors
            break
        }

        var matchingPortListeners: [SocketObservation] = []
        for descriptor in descriptors where descriptor.isSocket {
            guard let socket = source.socketObservation(processIdentifier, descriptor.fileDescriptor) else {
                guard source.processStartIdentity(processIdentifier) == processStartIdentity else {
                    throw DarwinProcessLoopbackListenerInspectionError
                        .processGenerationChanged(processIdentifier)
                }
                throw DarwinProcessLoopbackListenerInspectionError
                    .socketInventoryIncomplete(processIdentifier)
            }
            if socket.isTCPListener, socket.port == port {
                matchingPortListeners.append(socket)
            }
        }

        guard source.processStartIdentity(processIdentifier) == processStartIdentity else {
            throw DarwinProcessLoopbackListenerInspectionError.processGenerationChanged(processIdentifier)
        }
        guard !matchingPortListeners.isEmpty else {
            throw DarwinProcessLoopbackListenerInspectionError.listenerNotFound(processIdentifier, port)
        }

        let uniqueListeners = Set(matchingPortListeners)
        guard uniqueListeners.count == 1, let listener = uniqueListeners.first else {
            throw DarwinProcessLoopbackListenerInspectionError.listenerAmbiguous(
                processIdentifier,
                port,
                count: uniqueListeners.count)
        }
        guard let addressFamily = listener.loopbackAddressFamily else {
            throw DarwinProcessLoopbackListenerInspectionError.listenerNotLoopback(processIdentifier, port)
        }
        guard !listener.allowsPortReuse else {
            throw DarwinProcessLoopbackListenerInspectionError.listenerAllowsPortReuse(processIdentifier, port)
        }
        return DarwinProcessLoopbackListenerIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            addressFamily: addressFamily,
            port: port,
            kernelSocketAddress: listener.kernelSocketAddress,
            kernelProtocolControlBlock: listener.kernelProtocolControlBlock,
            kernelGeneration: listener.kernelGeneration)
    }
}

extension DarwinProcessLoopbackListenerInspector {
    struct Descriptor: Sendable {
        let fileDescriptor: Int32
        let isSocket: Bool
    }

    struct DescriptorBatch: Sendable {
        let descriptors: [Descriptor]
        let filledBuffer: Bool
        let hasPartialRecord: Bool
    }

    struct SocketObservation: Sendable, Hashable {
        let isTCPListener: Bool
        let port: UInt16
        let loopbackAddressFamily: DarwinLoopbackAddressFamily?
        let allowsPortReuse: Bool
        let kernelSocketAddress: UInt64
        let kernelProtocolControlBlock: UInt64
        let kernelGeneration: UInt64
    }

    struct InspectionSource: Sendable {
        let processStartIdentity: @Sendable (pid_t) -> UInt64?
        let descriptorCapacityLimit: @Sendable () -> Int
        let listDescriptors: @Sendable (pid_t, Int) -> DescriptorBatch?
        let socketObservation: @Sendable (pid_t, Int32) -> SocketObservation?

        static let live = InspectionSource(
            processStartIdentity: SystemIdentityResolver.processStartIdentity,
            descriptorCapacityLimit: {
                let bufferLimit = Int(Int32.max) / MemoryLayout<proc_fdinfo>.stride
                var descriptorLimit = rlimit()
                guard getrlimit(RLIMIT_NOFILE, &descriptorLimit) == 0,
                      descriptorLimit.rlim_cur != rlim_t(Int64.max)
                else {
                    return bufferLimit
                }
                return min(Int(clamping: descriptorLimit.rlim_cur), bufferLimit)
            },
            listDescriptors: { processIdentifier, capacity in
                var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
                let bufferByteCount = descriptors.count * MemoryLayout<proc_fdinfo>.stride
                let populatedBytes = descriptors.withUnsafeMutableBytes { buffer in
                    proc_pidinfo(
                        processIdentifier,
                        PROC_PIDLISTFDS,
                        0,
                        buffer.baseAddress,
                        Int32(buffer.count))
                }
                guard populatedBytes > 0 else { return nil }
                let populatedByteCount = Int(populatedBytes)
                let stride = MemoryLayout<proc_fdinfo>.stride
                let descriptorCount = min(capacity, populatedByteCount / stride)
                return DescriptorBatch(
                    descriptors: descriptors.prefix(descriptorCount).map {
                        Descriptor(
                            fileDescriptor: $0.proc_fd,
                            isSocket: $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET))
                    },
                    filledBuffer: populatedByteCount >= bufferByteCount,
                    hasPartialRecord: populatedByteCount % stride != 0)
            },
            socketObservation: { processIdentifier, descriptor in
                var socket = socket_fdinfo()
                let populatedBytes = withUnsafeMutableBytes(of: &socket) { buffer in
                    proc_pidfdinfo(
                        processIdentifier,
                        descriptor,
                        PROC_PIDFDSOCKETINFO,
                        buffer.baseAddress,
                        Int32(buffer.count))
                }
                guard Int(populatedBytes) == MemoryLayout<socket_fdinfo>.stride else { return nil }

                let tcp = socket.psi.soi_proto.pri_tcp
                let networkPort = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)
                let port = UInt16(bigEndian: networkPort)
                let family = DarwinProcessLoopbackListenerInspector.loopbackAddressFamily(tcp.tcpsi_ini)
                return SocketObservation(
                    isTCPListener: socket.psi.soi_kind == SOCKINFO_TCP && tcp.tcpsi_state == TSI_S_LISTEN,
                    port: port,
                    loopbackAddressFamily: family,
                    allowsPortReuse: Int32(socket.psi.soi_options) & SO_REUSEPORT != 0,
                    kernelSocketAddress: socket.psi.soi_so,
                    kernelProtocolControlBlock: socket.psi.soi_pcb,
                    kernelGeneration: tcp.tcpsi_ini.insi_gencnt)
            })
    }

    private static func loopbackAddressFamily(_ info: in_sockinfo) -> DarwinLoopbackAddressFamily? {
        if info.insi_vflag == UInt8(INI_IPV4) {
            let address = info.insi_laddr.ina_46.i46a_addr4.s_addr
            return address == in_addr_t(UInt32(INADDR_LOOPBACK).bigEndian) ? .ipv4 : nil
        }
        if info.insi_vflag == UInt8(INI_IPV6) {
            var address = info.insi_laddr.ina_6
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1 ? .ipv6 : nil
        }
        return nil
    }
}
