import Foundation
import Testing

@testable import LodgeKit

@Suite struct ResourceUsageTests {
    private func sample(pid: Int32 = 42, cpu: UInt64, at uptime: UInt64) -> ProcessSample {
        ProcessSample(pid: pid, cpuTimeNanoseconds: cpu, footprintBytes: 0, uptimeNanoseconds: uptime)
    }

    @Test func cpuPercentIsCPUTimeOverElapsedTime() {
        let old = sample(cpu: 1_000_000_000, at: 10_000_000_000)
        #expect(ResourceUsage.cpuPercent(from: old, to: sample(cpu: 1_500_000_000, at: 12_000_000_000)) == 25)
        #expect(ResourceUsage.cpuPercent(from: old, to: sample(cpu: 4_000_000_000, at: 11_000_000_000)) == 300)
        #expect(ResourceUsage.cpuPercent(from: old, to: sample(cpu: 1_000_000_000, at: 11_000_000_000)) == 0)
    }

    @Test func cpuPercentIsNilForADifferentPid() {
        let old = sample(pid: 1, cpu: 0, at: 0)
        #expect(ResourceUsage.cpuPercent(from: old, to: sample(pid: 2, cpu: 100, at: 1_000)) == nil)
    }

    @Test func cpuPercentIsNilWhenTimeDidNotAdvance() {
        let old = sample(cpu: 0, at: 5_000)
        #expect(ResourceUsage.cpuPercent(from: old, to: sample(cpu: 100, at: 5_000)) == nil)
        #expect(ResourceUsage.cpuPercent(from: old, to: sample(cpu: 100, at: 4_000)) == nil)
    }

    @Test func cpuPercentIsNilWhenCPUTimeGoesBackwards() {
        let old = sample(cpu: 1_000, at: 0)
        #expect(ResourceUsage.cpuPercent(from: old, to: sample(cpu: 500, at: 1_000)) == nil)
    }

    @Test func kindOfEachProcess() {
        let xpc = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices"
        let cases: [(String, ProcessKind)] = [
            ("/Applications/Lodge.app/Contents/MacOS/Lodge", .app),
            ("\(xpc)/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", .webContent),
            ("com.apple.WebKit.WebContent", .webContent),
            ("\(xpc)/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU", .gpu),
            ("com.apple.WebKit.Networking", .networking),
            ("com.apple.WebKit.Model", .otherWebKit),
            ("/usr/libexec/trustd", .other),
            ("Lodge", .other),
        ]
        for (path, kind) in cases {
            #expect(ResourceUsage.kind(ofPath: path) == kind, "\(path)")
        }
        #expect(Set(cases.map(\.1)) == Set(ProcessKind.allCases))
    }

    @Test func onlyWebKitKindsAreHelpers() {
        let helpers = ProcessKind.allCases.filter(\.isWebKitHelper)
        #expect(Set(helpers) == [.webContent, .gpu, .networking, .otherWebKit])
    }

    #if os(macOS)
        @Test func readsThisProcess() throws {
            let pid = getpid()
            let first = try #require(ProcessSample.read(pid: pid))
            var spin: UInt64 = 0
            for i in 0..<2_000_000 { spin &+= UInt64(i) }
            #expect(spin > 0)
            let second = try #require(ProcessSample.read(pid: pid))
            #expect(first.pid == pid)
            #expect(first.cpuTimeNanoseconds > 0)
            #expect(first.footprintBytes > 0)
            #expect(second.uptimeNanoseconds > first.uptimeNanoseconds)
            #expect(second.cpuTimeNanoseconds >= first.cpuTimeNanoseconds)
            #expect(ResourceUsage.cpuPercent(from: first, to: second) != nil)
        }

        @Test func readIsNilForAMissingProcess() {
            #expect(ProcessSample.read(pid: -1) == nil)
        }
    #endif

    @Test func formatFootprintUsesBinaryMemoryUnits() {
        let bytes: UInt64 = 537_185_484
        #expect(
            ResourceUsage.formatFootprint(bytes)
                == ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory))
        #expect(ResourceUsage.formatFootprint(bytes).contains("512"))
    }

    @Test func formatCPUShowsOneDecimalAndPercent() {
        #expect(ResourceUsage.formatCPU(12.5) == "12.5 %")
        #expect(ResourceUsage.formatCPU(0) == "0.0 %")
        #expect(ResourceUsage.formatCPU(312.04) == "312.0 %")
    }
}
