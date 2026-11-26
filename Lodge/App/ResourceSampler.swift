#if DEBUG
    import Darwin
    import LodgeKit
    import Observation

    /// What the Resource Monitor counts in Lodge itself (D4), read on the main actor.
    struct ResourceCounters: Equatable {
        var liveWebViews = 0
        var heldTabs = 0
        var miniPlayerOpen = false
        /// The site in the mini player, when it is open and its page names one.
        var miniPlayerSite: String?
        var workspacesLoaded = 0

        @MainActor
        init(coordinator: WorkspaceCoordinator) {
            let models = coordinator.loadedModels
            liveWebViews = coordinator.registry.liveViewCount
            heldTabs = models.reduce(0) { $0 + $1.heldNowCount }
            miniPlayerOpen = coordinator.miniPlayer.tab != nil
            miniPlayerSite = miniPlayerOpen ? coordinator.miniPlayer.caption : nil
            workspacesLoaded = models.count
        }

        init() {}

        /// "Closed", "Open", or "Open — example.com".
        var miniPlayerText: String {
            guard miniPlayerOpen else { return "Closed" }
            return miniPlayerSite.map { "Open — \($0)" } ?? "Open"
        }

        var summary: String {
            "views \(liveWebViews), held \(heldTabs), mini player \(miniPlayerText), workspaces \(workspacesLoaded)"
        }
    }

    /// One reading the Resource Monitor shows and logs: the same text in both places.
    struct ResourceReading: Equatable {
        /// CPU % (100 = one core) over the last second; nil until two samples are in.
        var cpuPercent: Double?
        var footprintBytes: UInt64?
        var counters = ResourceCounters()

        var cpuText: String { cpuPercent.map(ResourceUsage.formatCPU) ?? "--" }
        var footprintText: String { footprintBytes.map(ResourceUsage.formatFootprint) ?? "--" }
        var summary: String { "cpu \(cpuText), footprint \(footprintText), \(counters.summary)" }
    }

    /// Samples Lodge's own process (D2) every second off the main actor while started. The counters, which walk every
    /// loaded workspace's tabs on the main actor, are read every five seconds, when the summary is also logged (D3);
    /// only publishing a reading hops to the main actor.
    @MainActor
    @Observable
    final class ResourceSampler {
        private(set) var reading = ResourceReading()
        @ObservationIgnored private var task: Task<Void, Never>?
        @ObservationIgnored private let readCounters: @MainActor () -> ResourceCounters

        /// Ticks between two counter reads and log lines.
        nonisolated private static let countersEvery = 5

        init(readCounters: @escaping @MainActor () -> ResourceCounters) {
            self.readCounters = readCounters
        }

        func start() {
            guard task == nil else { return }
            task = Task.detached(priority: .utility) { [weak self] in
                let pid = getpid()
                var previous: ProcessSample?
                var tick = 0
                while !Task.isCancelled {
                    let sample = ProcessSample.read(pid: pid)
                    if sample == nil { Performance.logger.debug("sample failed: proc_pid_rusage refused; tick skipped") }
                    let cpu = sample.flatMap { new in previous.flatMap { ResourceUsage.cpuPercent(from: $0, to: new) } }
                    if let sample { previous = sample }
                    let isCountTick = tick % Self.countersEvery == 0
                    guard
                        let reading = await self?.publish(
                            cpu: cpu, footprint: sample?.footprintBytes, readingCounters: isCountTick)
                    else { break }
                    if isCountTick, tick > 0 {
                        Performance.logger.debug("\(reading.summary, privacy: .public)")
                    }
                    tick += 1
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        func stop() {
            task?.cancel()
            task = nil
        }

        isolated deinit {
            task?.cancel()
        }

        /// Shows the new reading, with the counters read again when asked (else as last read), and returns it.
        private func publish(cpu: Double?, footprint: UInt64?, readingCounters: Bool) -> ResourceReading {
            let new = ResourceReading(
                cpuPercent: cpu, footprintBytes: footprint,
                counters: readingCounters ? readCounters() : reading.counters)
            if new != reading { reading = new }
            return new
        }
    }
#endif
