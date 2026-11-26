import Foundation

/// One reading of a process: its pid, CPU time used so far, memory footprint, and the monotonic clock when read.
public struct ProcessSample: Sendable, Equatable {
    public var pid: Int32
    public var cpuTimeNanoseconds: UInt64
    public var footprintBytes: UInt64
    /// Monotonic clock when sampled.
    public var uptimeNanoseconds: UInt64

    public init(pid: Int32, cpuTimeNanoseconds: UInt64, footprintBytes: UInt64, uptimeNanoseconds: UInt64) {
        self.pid = pid
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.footprintBytes = footprintBytes
        self.uptimeNanoseconds = uptimeNanoseconds
    }
}

#if os(macOS)
    extension ProcessSample {
        /// Reads `pid` now: CPU time of every thread and `phys_footprint` (`proc_pid_rusage`), and the monotonic clock;
        /// nil when the kernel refuses, such as for a process the caller may not inspect. Lodge's sandbox lets it read
        /// itself, so the app and `lodge-perf` take the same reading.
        public static func read(pid: Int32) -> ProcessSample? {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard result == 0 else { return nil }
            let ticks = info.ri_user_time + info.ri_system_time
            return ProcessSample(
                pid: pid,
                cpuTimeNanoseconds: ticks * UInt64(timebase.numer) / UInt64(timebase.denom),
                footprintBytes: info.ri_phys_footprint,
                uptimeNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        }

        /// `proc_pid_rusage` counts CPU time in mach ticks.
        private static let timebase: mach_timebase_info_data_t = {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            return info
        }()
    }
#endif

public enum ProcessKind: String, Sendable, CaseIterable {
    case app, webContent, gpu, networking, otherWebKit, other

    /// One of WebKit's helper processes (`com.apple.WebKit.*`).
    public var isWebKitHelper: Bool { self != .app && self != .other }
}

public enum ResourceUsage {
    /// CPU % (100 = one core) between two samples of one pid; nil when pids differ, time did not advance, or CPU time went backwards.
    public static func cpuPercent(from old: ProcessSample, to new: ProcessSample) -> Double? {
        guard old.pid == new.pid,
              new.uptimeNanoseconds > old.uptimeNanoseconds,
              new.cpuTimeNanoseconds >= old.cpuTimeNanoseconds
        else { return nil }
        let cpu = Double(new.cpuTimeNanoseconds - old.cpuTimeNanoseconds)
        let elapsed = Double(new.uptimeNanoseconds - old.uptimeNanoseconds)
        return cpu / elapsed * 100
    }

    /// The kind from an executable path or name (`com.apple.WebKit.WebContent` → .webContent, `.GPU`, `.Networking`).
    public static func kind(ofPath path: String) -> ProcessKind {
        if path.hasSuffix("/Lodge.app/Contents/MacOS/Lodge") { return .app }
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix("com.apple.WebKit.WebContent") { return .webContent }
        if name.hasPrefix("com.apple.WebKit.GPU") { return .gpu }
        if name.hasPrefix("com.apple.WebKit.Networking") { return .networking }
        if name.hasPrefix("com.apple.WebKit.") { return .otherWebKit }
        return .other
    }

    /// "512.3 MB" style, binary units (ByteCountFormatter .memory).
    public static func formatFootprint(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    /// "12.5 %"
    public static func formatCPU(_ percent: Double) -> String {
        String(format: "%.1f %%", percent)
    }
}
