import Darwin

extension DaemonControlClient {
    nonisolated static func hasProcessTerminated(
        _ pid: pid_t,
        presenceError: (pid_t) -> Int32? = Self.processPresenceError,
        readBSDInfo: (pid_t, inout proc_bsdinfo) -> Int32 = Self.readBSDProcessInfo,
        readKernelInfo: (pid_t, inout kinfo_proc, inout Int) -> Int32 = Self.readKernelProcessInfo
    ) -> Bool {
        guard pid > 0 else { return false }
        if let error = presenceError(pid) {
            return error == ESRCH
        }

        // kill(pid, 0) still succeeds while an exited child awaits its parent's waitpid.
        var processInfo = proc_bsdinfo()
        if readBSDInfo(pid, &processInfo) == MemoryLayout<proc_bsdinfo>.stride,
           processInfo.pbi_pid == UInt32(pid) {
            return processInfo.pbi_status == UInt32(SZOMB)
        }

        var kernelInfo = kinfo_proc()
        var kernelInfoSize = MemoryLayout<kinfo_proc>.stride
        guard readKernelInfo(pid, &kernelInfo, &kernelInfoSize) == 0,
              kernelInfoSize == MemoryLayout<kinfo_proc>.stride,
              kernelInfo.kp_proc.p_pid == pid
        else { return false }
        return Int32(kernelInfo.kp_proc.p_stat) == SZOMB
    }

    private nonisolated static func processPresenceError(_ pid: pid_t) -> Int32? {
        kill(pid, 0) == 0 ? nil : errno
    }

    private nonisolated static func readBSDProcessInfo(_ pid: pid_t, _ info: inout proc_bsdinfo) -> Int32 {
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
    }

    private nonisolated static func readKernelProcessInfo(
        _ pid: pid_t,
        _ info: inout kinfo_proc,
        _ size: inout Int
    ) -> Int32 {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        return sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
    }
}
