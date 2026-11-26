import Darwin
import Dispatch
import Foundation
import LodgeKit

let usage = """
    Usage: lodge-perf [--once] [--interval S] [--pid N]

    Shows CPU and memory footprint of every running Lodge and the WebKit helpers it is responsible for.

      --once          print one table (two samples about 1 s apart) and exit
      --interval S    seconds between tables (default 1)
      --pid N         watch only the Lodge with this pid
      --help          show this message
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

struct Options {
    var once = false
    var interval = 1.0
    var pid: pid_t?
}

func parseOptions(_ args: [String]) -> Options {
    var options = Options()
    var rest = args[...]
    while let arg = rest.popFirst() {
        switch arg {
        case "--once": options.once = true
        case "--interval":
            guard let value = rest.popFirst().flatMap(Double.init), value > 0 else {
                fail("--interval needs a positive number of seconds\n\n\(usage)")
            }
            options.interval = value
        case "--pid":
            guard let value = rest.popFirst().flatMap(Int32.init), value > 0 else {
                fail("--pid needs a process id\n\n\(usage)")
            }
            options.pid = value
        case "--help", "-h":
            print(usage)
            exit(0)
        default: fail("unknown option \(arg)\n\n\(usage)")
        }
    }
    return options
}

func allPids() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let filled = pids.withUnsafeMutableBufferPointer {
        proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
    }
    return Array(pids.prefix(Int(max(filled, 0)))).filter { $0 > 0 }
}

func path(of pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
}

func uid(of pid: pid_t) -> uid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info.pbi_uid
}

typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t
let responsibleFor: ResponsibleFor? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: ResponsibleFor.self) }

struct Watched {
    var pid: pid_t
    var kind: ProcessKind
}

/// What discovery reads about a pid once, when it first appears: its path, the process responsible for it and its
/// user never change while it runs, and macOS hands out pids in rising order, so none is reused between two rounds.
struct Seen {
    /// nil when its path cannot be read.
    var kind: ProcessKind?
    /// nil without the responsibility lookup.
    var responsible: pid_t?
    /// Read only without the responsibility lookup, which needs it instead.
    var uid: uid_t?

    init(_ pid: pid_t) {
        kind = path(of: pid).map(ResourceUsage.kind(ofPath:))
        responsible = responsibleFor?(pid)
        uid = responsibleFor == nil ? LodgePerf.uid(of: pid) : nil
    }
}

/// Lodge processes plus their helpers; nil when no Lodge (or not the one `--pid` names) is running. `seen` keeps what
/// was read about each running pid, so a round reads only the pids that are new.
func discover(only wanted: pid_t?, seen: inout [pid_t: Seen]) -> [Watched]? {
    var current: [pid_t: Seen] = [:]
    for pid in allPids() { current[pid] = seen[pid] ?? Seen(pid) }
    seen = current
    let lodges = Set(current.filter { $0.value.kind == .app && (wanted == nil || $0.key == wanted) }.keys)
    guard !lodges.isEmpty else { return nil }
    let lodgeUids = Set(lodges.compactMap { current[$0]?.uid })
    return current.compactMap { pid, info in
        guard let kind = info.kind else { return nil }
        let ours = lodges.contains(pid)
            || (info.responsible.map(lodges.contains) ?? (kind.isWebKitHelper && info.uid.map(lodgeUids.contains) == true))
        return ours ? Watched(pid: pid, kind: kind) : nil
    }
}

func samples(of watched: [Watched]) -> [pid_t: ProcessSample] {
    Dictionary(watched.compactMap { w in ProcessSample.read(pid: w.pid).map { (w.pid, $0) } }, uniquingKeysWith: { a, _ in a })
}

let kindOrder = Dictionary(uniqueKeysWithValues: ProcessKind.allCases.enumerated().map { ($1, $0) })

func table(_ watched: [Watched], old: [pid_t: ProcessSample], new: [pid_t: ProcessSample]) -> String {
    let pad = { (s: String, n: Int) in String(repeating: " ", count: max(n - s.count, 0)) + s }
    let padRight = { (s: String, n: Int) in s + String(repeating: " ", count: max(n - s.count, 0)) }
    var lines = [padRight("PID", 8) + padRight("KIND", 13) + pad("CPU", 10) + pad("FOOTPRINT", 12)]
    var totalCPU = 0.0
    var totalFootprint: UInt64 = 0
    let rows = watched.filter { new[$0.pid] != nil }
        .sorted { (kindOrder[$0.kind]!, $0.pid) < (kindOrder[$1.kind]!, $1.pid) }
    for row in rows {
        let current = new[row.pid]!
        let cpu = old[row.pid].flatMap { ResourceUsage.cpuPercent(from: $0, to: current) }
        totalCPU += cpu ?? 0
        totalFootprint += current.footprintBytes
        lines.append(padRight("\(row.pid)", 8) + padRight(row.kind.rawValue, 13)
            + pad(cpu.map(ResourceUsage.formatCPU) ?? "-", 10) + pad(ResourceUsage.formatFootprint(current.footprintBytes), 12))
    }
    lines.append(padRight("TOTAL", 8) + padRight("\(rows.count) processes", 13)
        + pad(ResourceUsage.formatCPU(totalCPU), 10) + pad(ResourceUsage.formatFootprint(totalFootprint), 12))
    if responsibleFor == nil {
        lines.append("(unattributed: every com.apple.WebKit.* helper of the same user, not only Lodge's)")
    }
    return lines.joined(separator: "\n")
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
let notRunning = options.pid.map { "No running Lodge has pid \($0)." } ?? "Lodge is not running."
let isTTY = isatty(STDOUT_FILENO) == 1

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interrupt.setEventHandler { @Sendable in
    if isatty(STDOUT_FILENO) == 1 { fputs("\n", stdout) }
    exit(0)
}
interrupt.resume()

var seen: [pid_t: Seen] = [:]
guard var watched = discover(only: options.pid, seen: &seen) else { fail(notRunning) }
var previous = samples(of: watched)
let interval = options.once ? 1.0 : options.interval

while true {
    Thread.sleep(forTimeInterval: interval)
    guard let found = discover(only: options.pid, seen: &seen) else { fail(notRunning) }
    watched = found
    let current = samples(of: watched)
    let output = table(watched, old: previous, new: current)
    if !options.once { print(isTTY ? "\u{1B}[H\u{1B}[2J" : "", terminator: isTTY ? "" : "\n") }
    print(output)
    fflush(stdout)
    if options.once { break }
    previous = current
}
