import Darwin
import Foundation

/// 当前进程的资源占用快照；CPU 为累计秒数，两次采样相减得到占用率。
struct ProcessSample: Sendable {
    /// 与活动监视器「内存」一致（phys_footprint）。
    let footprint: UInt64
    let peakFootprint: UInt64
    let resident: UInt64
    let threads: Int
    let cpuSeconds: Double
    /// 已退出并回收的子进程（Git）累计 CPU 秒数。
    let childCPUSeconds: Double
    let uptime: UInt64

    static func current() -> Self? {
        let pid = getpid()
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let threads = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size ? Int(task.pti_threadnum) : 0
        // ri_user_time 在 Apple Silicon 上是 mach tick，getrusage 的 timeval 单位确定。
        var own = rusage()
        var children = rusage()
        getrusage(RUSAGE_SELF, &own)
        getrusage(RUSAGE_CHILDREN, &children)
        return Self(footprint: info.ri_phys_footprint, peakFootprint: info.ri_lifetime_max_phys_footprint,
                    resident: info.ri_resident_size, threads: threads,
                    cpuSeconds: seconds(own.ru_utime) + seconds(own.ru_stime),
                    childCPUSeconds: seconds(children.ru_utime) + seconds(children.ru_stime),
                    uptime: DispatchTime.now().uptimeNanoseconds)
    }

    /// 相对上一次采样的 CPU 占用率，单核满载为 100%，多核可超过。
    func cpuPercent(since previous: Self, children: Bool = false) -> Double {
        let elapsed = Double(uptime - previous.uptime) / 1_000_000_000
        guard elapsed > 0 else { return 0 }
        let used = children ? childCPUSeconds - previous.childCPUSeconds : cpuSeconds - previous.cpuSeconds
        return max(0, used / elapsed * 100)
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}
