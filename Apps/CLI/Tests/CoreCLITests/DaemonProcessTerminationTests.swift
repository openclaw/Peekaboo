import Darwin
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct DaemonProcessTerminationTests {
    @Test(arguments: [ESRCH, EPERM, EINVAL])
    func `only confirmed absence skips metadata`(_ error: Int32) {
        #expect(DaemonControlClient.hasProcessTerminated(
            42,
            presenceError: { _ in error },
            readBSDInfo: { _, _ in Issue.record("Unexpected metadata read"); return 0 },
            readKernelInfo: { _, _, _ in Issue.record("Unexpected fallback read"); return -1 }
        ) == (error == ESRCH))
    }

    @Test(arguments: [SZOMB, SRUN, SSLEEP, SSTOP, SIDL])
    func `complete matching BSD metadata proves only a zombie terminal`(_ state: Int32) {
        #expect(DaemonControlClient.hasProcessTerminated(
            42,
            presenceError: { _ in nil },
            readBSDInfo: { pid, info in
                info.pbi_pid = UInt32(pid)
                info.pbi_status = UInt32(state)
                return Int32(MemoryLayout<proc_bsdinfo>.stride)
            },
            readKernelInfo: { _, _, _ in Issue.record("Valid BSD state must not fall back"); return -1 }
        ) ==
            (state == SZOMB))
    }

    @Test(arguments: [false, true])
    func `kernel fallback can confirm a zombie when BSD metadata is short or mismatched`(mismatch: Bool) {
        #expect(DaemonControlClient.hasProcessTerminated(
            42,
            presenceError: { _ in nil },
            readBSDInfo: { _, info in
                info.pbi_pid = 99
                info.pbi_status = UInt32(SZOMB)
                return mismatch ? Int32(MemoryLayout<proc_bsdinfo>.stride) : 0
            },
            readKernelInfo: { pid, info, size in
                info.kp_proc.p_pid = pid
                info.kp_proc.p_stat = Int8(SZOMB)
                size = MemoryLayout<kinfo_proc>.stride
                return 0
            }
        ))
    }

    @Test(arguments: ["error", "short", "mismatch", "live"])
    func `unreadable or nonterminal fallback never confirms exit`(_ variant: String) {
        #expect(!DaemonControlClient.hasProcessTerminated(
            42,
            presenceError: { _ in nil },
            readBSDInfo: { _, _ in 0 },
            readKernelInfo: { pid, info, size in
                info.kp_proc.p_pid = variant == "mismatch" ? pid + 1 : pid
                info.kp_proc.p_stat = Int8(variant == "live" ? SRUN : SZOMB)
                size = variant == "short" ? 0 : MemoryLayout<kinfo_proc>.stride
                return variant == "error" ? -1 : 0
            }
        ))
    }

    @Test(arguments: [pid_t(0), -1])
    func `invalid PID never probes a process group`(_ pid: pid_t) {
        #expect(!DaemonControlClient.hasProcessTerminated(pid, presenceError: { _ in
            Issue.record("Invalid PID reached native presence probe")
            return ESRCH
        }))
    }
}
