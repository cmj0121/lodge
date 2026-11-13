import AppKit
import LodgeKit
import Observation
import WebKit
import os

/// Runs every download and keeps the Downloads list (D4): picks where each file goes (D1), writes it as a
/// `.lodgedownload` partial moved to its final file on finish (D6, `DownloadFiles`), bookmarks the finished file
/// (D7), and saves the list to downloads.json after each state change, in order, off the main actor. Nothing is
/// written before `restore(_:)` has merged the list saved by the last run.
@MainActor
@Observable
final class DownloadManager: NSObject, WKDownloadDelegate {
    nonisolated static let logger = Logger(subsystem: "dev.lodge", category: "downloads")

    /// Partials that cannot sit beside their final file wait in the container's tmp/Downloads.
    nonisolated static let files = DownloadFiles(
        stagingFolder: FileManager.default.temporaryDirectory.appending(path: "Downloads", directoryHint: .isDirectory))

    /// A download WebKit is running for an item.
    private struct Active {
        let id: UUID
        let download: WKDownload
        /// The store of the tab it came from (a Retry's: its row's), so a workspace's downloads can be found.
        let store: StoreRef
        /// The row a Retry replaces once this download has its destination; until then that row stands for it.
        var replacing: UUID?
        var observations: [NSKeyValueObservation] = []
        /// Open while the item waits for its location.
        var panel: NSSavePanel?
        /// The final (reserved) file, where its bytes are written meanwhile, and how the one becomes the other.
        var finalURL: URL?
        var partialURL: URL?
        var placement = DownloadFiles.Placement.unique
        /// The custom folder, accessed until the download ends.
        var scopedFolder: URL?
        /// The "download multiple files" prompt, answered before the download gets a destination.
        var permission: Task<Bool, Never>?
    }

    private(set) var list = DownloadList()
    /// An item ended since the popover last opened.
    private(set) var hasUnseenEnded = false
    /// Finished items whose file cannot be reached (D5 "File moved or deleted"); kept in memory only.
    private(set) var missing: Set<UUID> = []
    /// Finished private files whose source address could not be removed; kept in memory only, as their rows are.
    private(set) var keptOrigin: Set<UUID> = []

    /// Partials created before this belong to an earlier run.
    @ObservationIgnored let createdAt = Date()
    @ObservationIgnored private var active: [ObjectIdentifier: Active] = [:]
    /// Final files of active items (standardized), so two downloads never pick the same file (D9).
    @ObservationIgnored private var reserved: Set<URL> = []
    /// Rows with a Retry in flight.
    @ObservationIgnored private var retrying: Set<UUID> = []
    /// Retries still waiting for WebKit's download, voided when their store is cancelled.
    @ObservationIgnored private var pendingRetries = PendingRetries()
    @ObservationIgnored private var pendingProgress: [UUID: (received: Int64, total: Int64?)] = [:]
    @ObservationIgnored private var throttle = DownloadProgressThrottle()
    @ObservationIgnored private var isRestored = false
    /// Which pages may start downloads (CWE-770); answers last until quit.
    @ObservationIgnored private var gate = DownloadGate()
    /// The "Too many downloads" alert is up, so another refusal does not stack one more.
    @ObservationIgnored private var isShowingTooMany = false
    /// `refreshMissing()` runs; a newer one voids the older.
    @ObservationIgnored private var refreshes = LatestOnly()
    @ObservationIgnored private let file: DownloadsFile?
    @ObservationIgnored private let writes = DispatchQueue(label: "dev.lodge.downloads.write", qos: .utility)
    @ObservationIgnored private let defaults: UserDefaults
    /// The data store a Retry sends its request on, nil once that store's workspace is gone. Without a coordinator
    /// (layout renders) only Default's.
    @ObservationIgnored var dataStore: @MainActor (StoreRef) -> WKWebsiteDataStore? = { $0 == .global ? .default() : nil }
    /// Called with an anonymous tab's store when a download on it starts running, so the store outlives its tab
    /// until the download ends, and then with nil.
    @ObservationIgnored var storeHold: @MainActor (_ download: UUID, _ store: StoreRef?) -> Void = { _, _ in }

    /// `directory` holds downloads.json; nil keeps the list in memory only.
    init(directory: URL?, defaults: UserDefaults = .standard) {
        file = directory.map(DownloadsFile.init(directory:))
        self.defaults = defaults
    }

    // MARK: Launch and quit

    /// Loads downloads.json and turns its active items into interrupted ones, then deletes the partials of every
    /// interrupted item and the staged ones, all created before `cutoff` (D6), inside the custom folder's access when
    /// `folderBookmark` resolves. Runs off the main actor.
    nonisolated static func load(
        from directory: URL, createdBefore cutoff: Date, folderBookmark: Data?
    ) -> DownloadList {
        var list: DownloadList
        switch DownloadsFile(directory: directory).load() {
        case .missing:
            list = DownloadList()
        case .loaded(let loaded):
            list = loaded
        case .setAside(let reason, let moveFailure):
            logger.error("Cannot read downloads, setting them aside: \(reason.localizedDescription, privacy: .public)")
            if let moveFailure {
                logger.error("Cannot set downloads aside: \(moveFailure.localizedDescription, privacy: .public)")
            }
            list = DownloadList()
        }
        _ = list.interruptActive(at: Date())
        files.cleanUp(
            list.items, createdBefore: cutoff, downloadsFolder: downloadsFolder,
            folder: folderBookmark.flatMap(resolveFolder))
        return list
    }

    /// Puts the saved list, without any private row, under the downloads started since launch, then saves the result.
    func restore(_ saved: DownloadList) {
        list = DownloadList(items: list.items + saved.persistable().items)
        isRestored = true
        persist()
    }

    /// At quit: cancels every download, deletes its partial, marks it interrupted and writes the list, without its
    /// private rows, before returning.
    func cancelAllForQuit() {
        for entry in active.values {
            storeHold(entry.id, nil)
            if let panel = entry.panel { close(panel) }
            entry.download.cancel(nil)
            entry.observations.forEach { $0.invalidate() }
            if let partial = entry.partialURL { DownloadFiles.deletePartial(partial) }
            entry.scopedFolder?.stopAccessingSecurityScopedResource()
        }
        active = [:]
        reserved = []
        applyPendingProgress()
        _ = list.interruptActive(at: Date())
        guard isRestored, let file else { return }
        let snapshot = list.persistable()
        writes.sync { Self.write(snapshot, to: file) }
    }

    // MARK: Starting

    /// Takes over a download a tab's navigation became, when `DownloadGate` lets `site` start it. Every workspace's
    /// downloads join the one list; an Anonymous tab's are private: never saved, and their files keep no origin.
    func start(_ download: WKDownload, store: StoreRef, site: Origin?, userInitiated: Bool, isMainFrame: Bool) {
        let decision = gate.decide(
            site: site, userInitiated: userInitiated, isMainFrame: isMainFrame, activeCount: active.count)
        switch decision {
        case .allow:
            track(download, store: store, replacing: nil)
        case .ask:
            guard let site else {
                download.cancel(nil)
                return
            }
            let window = download.webView?.window
            track(
                download, store: store, replacing: nil,
                permission: Task { await askPermission(for: site, in: window) })
        case .refuse(let refusal):
            download.cancel(nil)
            if case .ephemeral = store {
                Self.logger.notice("Refused a private download: \(String(describing: refusal))")
            } else {
                let from = site?.description ?? "a page without a site"
                Self.logger.notice("Refused a download from \(from, privacy: .private): \(String(describing: refusal))")
            }
            if refusal == .tooMany { alertTooMany(in: download.webView?.window) }
        }
    }

    private func track(
        _ download: WKDownload, store: StoreRef, replacing: UUID?, permission: Task<Bool, Never>? = nil
    ) {
        download.delegate = self
        let id = UUID()
        active[ObjectIdentifier(download)] = Active(
            id: id, download: download, store: store, replacing: replacing, permission: permission)
        if case .ephemeral = store { storeHold(id, store) }
    }

    private func alertTooMany(in window: NSWindow?) {
        guard !isShowingTooMany else { return }
        isShowingTooMany = true
        let alert = NSAlert()
        alert.messageText = "Too many downloads are running."
        Task {
            if let window {
                await alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            isShowingTooMany = false
        }
    }

    /// Asks whether `site` may download multiple files, as a sheet on the tab's window, and records the answer.
    private func askPermission(for site: Origin, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = DownloadGate.prompt(for: site)
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        let response = if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        let allowed = response == .alertFirstButtonReturn
        gate.answer(allowed, for: site)
        return allowed
    }

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
    ) async -> URL? {
        guard let entry = active[ObjectIdentifier(download)] else { return nil }
        if let permission = entry.permission {
            guard await permission.value else {
                end(download, as: .cancelled)
                return nil
            }
            // The download may have ended, by a quit, while the prompt was open.
            guard active[ObjectIdentifier(download)] != nil else { return nil }
            update(download) { $0.permission = nil }
        }
        let request = download.originalRequest
        let name = DownloadNaming.sanitize(suggestedFilename)
        list.add(
            DownloadItem(
                id: entry.id, sourceURL: request?.url ?? response.url, method: request?.httpMethod ?? "GET",
                fileName: name, totalBytes: response.expectedContentLength >= 0 ? response.expectedContentLength : nil,
                startedAt: Date(), store: entry.store))
        persist()

        let finalURL: URL
        var placement = DownloadFiles.Placement.unique
        var scopedFolder: URL?
        let destination = DownloadDestination.resolve(
            settings, downloadsFolder: Self.downloadsFolder, resolve: Self.resolveFolder)
        switch destination {
        case .ask:
            guard let chosen = await askLocation(for: download, name: name) else {
                end(download, as: .cancelled)
                return nil
            }
            // The download may have ended, by a quit or the list, while the panel was open.
            guard active[ObjectIdentifier(download)] != nil else { return nil }
            // The user approved this exact file, overwrite included.
            guard !reserved.contains(chosen.standardizedFileURL) else {
                let reason = "Another download is already saving to “\(chosen.lastPathComponent)”."
                end(download, as: .failed(reason: reason))
                return nil
            }
            finalURL = chosen
            placement = .exact
        case .folder(var folder, let scoped):
            if scoped {
                if folder.startAccessingSecurityScopedResource() {
                    scopedFolder = folder
                } else {
                    Self.logger.error("Cannot access the downloads folder, saving to Downloads instead")
                    folder = Self.downloadsFolder
                }
            }
            finalURL = uniqueURL(for: name, in: folder)
        case .fallback(let folder):
            finalURL = uniqueURL(for: name, in: folder)
        }
        let partialURL = Self.files.partialURL(for: finalURL, id: entry.id)
        reserved.insert(finalURL.standardizedFileURL)
        update(download) {
            $0.finalURL = finalURL
            $0.partialURL = partialURL
            $0.placement = placement
            $0.scopedFolder = scopedFolder
            $0.observations = observeProgress(of: download, id: entry.id)
            $0.replacing = nil
        }
        if let replaced = entry.replacing {
            retrying.remove(replaced)
            list.remove(replaced)
            missing.remove(replaced)
        }
        list.update(entry.id) {
            $0.fileName = finalURL.lastPathComponent
            $0.directory = finalURL.deletingLastPathComponent()
            _ = $0.transition(to: .running, at: Date())
        }
        persist()
        return partialURL
    }

    /// Shows the save panel as a sheet on the tab's window (a Retry has none: then a panel of its own) and returns
    /// the chosen file; nil when it is cancelled.
    private func askLocation(for download: WKDownload, name: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = Self.downloadsFolder
        panel.canCreateDirectories = true
        update(download) { $0.panel = panel }
        let response: NSApplication.ModalResponse
        if let window = download.webView?.window ?? NSApp.mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        update(download) { $0.panel = nil }
        return response == .OK ? panel.url : nil
    }

    /// Ends the panel, and its sheet when cancelling did not.
    private func close(_ panel: NSSavePanel) {
        panel.cancel(nil)
        if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }
    }

    private var settings: DownloadSettings {
        DownloadSettings(
            folderBookmark: defaults.data(forKey: DownloadSettings.folderKey),
            askEachTime: defaults.bool(forKey: DownloadSettings.askKey))
    }

    private nonisolated static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    private nonisolated static func resolveFolder(_ bookmark: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
            bookmarkDataIsStale: &isStale)
    }

    private func uniqueURL(for name: String, in folder: URL) -> URL {
        folder.appending(path: DownloadNaming.unique(name, in: folder, reserved: reservedNames(in: folder)))
    }

    private func reservedNames(in folder: URL) -> Set<String> {
        let folder = folder.standardizedFileURL
        return Set(reserved.filter { $0.deletingLastPathComponent() == folder }.map(\.lastPathComponent))
    }

    private func update(_ download: WKDownload, _ change: (inout Active) -> Void) {
        let key = ObjectIdentifier(download)
        guard var entry = active[key] else { return }
        change(&entry)
        active[key] = entry
    }

    // MARK: Progress

    private func observeProgress(of download: WKDownload, id: UUID) -> [NSKeyValueObservation] {
        let tick: @Sendable (Progress) -> Void = { [weak self] progress in
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in self?.progressChanged(id, received: received, total: total >= 0 ? total : nil) }
        }
        return [
            download.progress.observe(\.completedUnitCount) { progress, _ in tick(progress) },
            download.progress.observe(\.totalUnitCount) { progress, _ in tick(progress) },
        ]
    }

    /// Keeps the most bytes seen per item, as ticks hop to the main actor one task each and may land out of order.
    private func progressChanged(_ id: UUID, received: Int64, total: Int64?) {
        guard list[id]?.state == .running else { return }
        let seen = max(received, pendingProgress[id]?.received ?? 0)
        pendingProgress[id] = (seen, total ?? pendingProgress[id]?.total)
        switch throttle.offer(at: ProcessInfo.processInfo.systemUptime) {
        case .emit:
            applyPendingProgress()
        case .schedule(let delay):
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.throttle.flushed(at: ProcessInfo.processInfo.systemUptime)
                self.applyPendingProgress()
            }
        case .wait:
            break
        }
    }

    private func applyPendingProgress() {
        let pending = pendingProgress
        pendingProgress = [:]
        for (id, progress) in pending where list[id]?.state == .running {
            list.update(id) {
                $0.receivedBytes = max($0.receivedBytes, progress.received)
                if let total = progress.total { $0.totalBytes = total }
            }
        }
    }

    // MARK: Ending

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = active[ObjectIdentifier(download)] else { return }
        guard let finalURL = entry.finalURL, let partialURL = entry.partialURL else {
            end(download, as: .failed(reason: "The download finished before it had a place to go."))
            return
        }
        do {
            reserved.remove(finalURL.standardizedFileURL)
            let target = try Self.files.finish(
                partialURL, to: finalURL, placement: entry.placement,
                reserved: reservedNames(in: finalURL.deletingLastPathComponent()))
            do {
                try Quarantine.ensure(target)
            } catch {
                Self.logger.error("Cannot quarantine a download: \(error.localizedDescription, privacy: .public)")
            }
            if case .ephemeral = entry.store { stripProvenance(of: target, id: entry.id) }
            let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                ?? download.progress.completedUnitCount
            let bookmark: Data?
            do {
                bookmark = try target.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch {
                Self.logger.error("Cannot bookmark a download: \(error.localizedDescription, privacy: .public)")
                bookmark = nil
            }
            end(download, as: .finished) {
                $0.fileName = target.lastPathComponent
                $0.fileURL = target
                $0.bookmark = bookmark
                $0.receivedBytes = size
                $0.totalBytes = size
            }
        } catch {
            Self.logger.error("Cannot move a finished download: \(error.localizedDescription, privacy: .public)")
            end(download, as: .failed(reason: error.localizedDescription))
        }
    }

    /// Clears a private file's origin; when that fails, at least its where-froms, else its row says the source stayed.
    private func stripProvenance(of file: URL, id: UUID) {
        do {
            try Provenance.strip(file)
        } catch {
            Self.logger.error("Cannot clear a private download's origin: \(error.localizedDescription, privacy: .public)")
            do {
                try Provenance.removeWhereFroms(file)
            } catch {
                Self.logger.error(
                    "Cannot remove a private download's source: \(error.localizedDescription, privacy: .public)")
                keptOrigin.insert(id)
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        end(download, as: .failed(reason: error.localizedDescription))
    }

    /// Ends the download's item as `state`: stops tracking it, closes its panel, deletes its partial unless it
    /// finished, releases its name and the folder, and saves. A Retry that ends before its destination leaves only
    /// the old row, which takes a failure's reason.
    private func end(
        _ download: WKDownload, as state: DownloadItem.State, _ change: (inout DownloadItem) -> Void = { _ in }
    ) {
        guard let entry = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if case .ephemeral = entry.store { storeHold(entry.id, nil) }
        if let panel = entry.panel { close(panel) }
        entry.observations.forEach { $0.invalidate() }
        if state != .finished, let partial = entry.partialURL { DownloadFiles.deletePartial(partial) }
        if let finalURL = entry.finalURL { reserved.remove(finalURL.standardizedFileURL) }
        entry.scopedFolder?.stopAccessingSecurityScopedResource()
        pendingProgress[entry.id] = nil
        var didEnd = false
        if let replaced = entry.replacing {
            retrying.remove(replaced)
            list.remove(entry.id)
            if case .failed = state {
                didEnd = list.update(replaced) {
                    $0.state = state
                    $0.endedAt = Date()
                }
            }
        } else {
            list.update(entry.id) { item in
                guard item.transition(to: state, at: Date()) else { return }
                change(&item)
                didEnd = true
            }
        }
        if didEnd { hasUnseenEnded = true }
        persist()
    }

    // MARK: Row actions

    /// Stops an active item: its panel is closed, or WebKit stops and the partial is deleted.
    func cancel(_ id: UUID) {
        guard let entry = active.values.first(where: { $0.id == id }) else { return }
        if let panel = entry.panel {
            // `askLocation` sees the cancel and ends the item.
            close(panel)
            return
        }
        entry.download.cancel(nil)
        end(entry.download, as: .cancelled)
    }

    /// Cancels every download still running on the store, as each row's Cancel would; finished rows stay.
    func cancel(store: StoreRef) {
        pendingRetries.cancel(store: store)
        for entry in active.values where entry.store == store { cancel(entry.id) }
    }

    /// Downloads an ended GET http(s) item again on the store it came from (D8), once at a time per row; the row is
    /// replaced by the new one when it gets its destination. A finished item retries only once its file is missing.
    /// A row whose workspace is gone, or whose Anonymous tab has closed with no download left on its store, is not
    /// retried.
    func retry(_ id: UUID) {
        guard let item = list[id], item.canRetry(isMissing: missing.contains(id)), let url = item.sourceURL,
            !retrying.contains(id)
        else { return }
        guard let store = item.retryStore, let dataStore = dataStore(store) else {
            let alert = NSAlert()
            alert.messageText =
                item.isPrivate
                ? "This download's anonymous tab has closed, so it can't be retried."
                : "This download's workspace no longer exists, so it can't be retried."
            present(alert, in: NSApp.keyWindow)
            return
        }
        retrying.insert(id)
        pendingRetries.begin(id, on: store)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        // A download outlives the view that started it.
        let view = WKWebView(frame: .zero, configuration: config)
        Task {
            let download = await view.startDownload(using: URLRequest(url: url))
            guard pendingRetries.finish(id, storeExists: self.dataStore(store) != nil) else {
                download.cancel(nil)
                retrying.remove(id)
                return
            }
            track(download, store: store, replacing: id)
        }
    }

    /// Opens the finished file, after a confirmation when it is an app or script (`DownloadOpenRisk`).
    func open(_ id: UUID) {
        act(on: id) { url in
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            guard DownloadOpenRisk.isAppOrScript(fileName: url.lastPathComponent, contentType: type) else {
                return openQuarantined(url, isAppOrScript: false)
            }
            Task { await confirmOpen(id, name: url.lastPathComponent) }
            return true
        }
    }

    private func confirmOpen(_ id: UUID, name: String) async {
        let alert = NSAlert()
        alert.messageText = DownloadOpenRisk.confirmation(for: name)
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let response =
            if let window = NSApp.mainWindow { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return }
        act(on: id) { openQuarantined($0, isAppOrScript: true) }
    }

    /// Opens `url` once it carries the quarantine mark, so Gatekeeper checks it (CWE-693). An app or script that
    /// cannot be marked is not opened: the user is told, and true is returned, as the file is there; any other file
    /// opens anyway.
    private func openQuarantined(_ url: URL, isAppOrScript: Bool) -> Bool {
        do {
            try Quarantine.ensure(url)
        } catch {
            Self.logger.error("Cannot quarantine a download: \(error.localizedDescription, privacy: .public)")
            guard isAppOrScript else { return NSWorkspace.shared.open(url) }
            let alert = NSAlert()
            alert.messageText = "Lodge can't open “\(url.lastPathComponent)” safely."
            present(alert, in: NSApp.mainWindow)
            return true
        }
        return NSWorkspace.shared.open(url)
    }

    func showInFinder(_ id: UUID) {
        act(on: id) {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
            return true
        }
    }

    /// Runs `use` on the finished item's file; when it cannot be reached or `use` fails, alerts and marks the row
    /// missing (D5).
    private func act(on id: UUID, _ use: (URL) -> Bool) {
        guard let item = list[id], item.state == .finished else { return }
        guard withFile(of: item, use) == true else {
            missing.insert(id)
            let alert = NSAlert()
            alert.messageText = "Lodge can't open “\(item.fileName)”. It may have been moved or deleted."
            present(alert, in: NSApp.mainWindow)
            return
        }
        missing.remove(id)
    }

    /// Checks every finished item's file, for the popover to show "File moved or deleted".
    /// The checks run off the main actor; only the newest run's result is published.
    func refreshMissing() {
        let finished = list.items.filter { $0.state == .finished }
        let ticket = refreshes.begin()
        Task {
            let checks = await Task.detached(priority: .utility) {
                finished.map { item in (id: item.id, check: Self.check(item, { _ in () })) }
            }.value
            guard refreshes.accepts(ticket) else { return }
            var found: Set<UUID> = []
            for (id, check) in checks {
                guard list[id]?.state == .finished else { continue }
                if check.result == nil { found.insert(id) }
                applyFresh(check, to: id)
            }
            if found != missing { missing = found }
        }
    }

    /// What `check` found: `use`'s result (nil when the file cannot be reached) and a refreshed bookmark.
    private struct Check<Value: Sendable>: Sendable {
        var result: Value?
        var fresh: (url: URL, bookmark: Data)?
    }

    /// Resolves the item's bookmark, refreshing a stale one, and runs `use` on its file while access is held. Without
    /// a bookmark the file counts as missing: the stored `fileURL` is never used on its own.
    private nonisolated static func check<Value: Sendable>(
        _ item: DownloadItem, _ use: (URL) -> Value
    ) -> Check<Value> {
        var url: URL?
        var accessing = false
        var fresh: (url: URL, bookmark: Data)?
        if let bookmark = item.bookmark {
            var isStale = false
            url = try? URL(
                resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                bookmarkDataIsStale: &isStale)
            if let url {
                accessing = url.startAccessingSecurityScopedResource()
                if isStale,
                    let data = try? url.bookmarkData(
                        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                {
                    fresh = (url, data)
                }
            }
        }
        defer { if accessing { url?.stopAccessingSecurityScopedResource() } }
        guard let url, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return Check(result: nil, fresh: fresh)
        }
        return Check(result: use(url), fresh: fresh)
    }

    private func applyFresh<Value>(_ check: Check<Value>, to id: UUID) {
        guard let fresh = check.fresh else { return }
        list.update(id) {
            $0.bookmark = fresh.bookmark
            $0.fileURL = fresh.url
        }
        persist()
    }

    /// Runs `use` on the item's file on the main actor; nil when it cannot be reached.
    private func withFile<Value: Sendable>(of item: DownloadItem, _ use: (URL) -> Value) -> Value? {
        let check = Self.check(item, use)
        applyFresh(check, to: item.id)
        return check.result
    }

    /// Drops an ended row.
    func remove(_ id: UUID) {
        guard let item = list[id], !item.state.isActive else { return }
        list.remove(id)
        missing.remove(id)
        keptOrigin.remove(id)
        persist()
    }

    func clearEnded() {
        list.clearEnded()
        missing = missing.filter { list[$0] != nil }
        keptOrigin = keptOrigin.filter { list[$0] != nil }
        persist()
    }

    /// The popover opened.
    func markSeen() {
        if hasUnseenEnded { hasUnseenEnded = false }
    }

    // MARK: Files

    private func present(_ alert: NSAlert, in window: NSWindow?) {
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Queues a write of the list as it is now; writes run one at a time, in order.
    private func persist() {
        guard isRestored, let file else { return }
        let snapshot = list.persistable()
        writes.async { Self.write(snapshot, to: file) }
    }

    private nonisolated static func write(_ list: DownloadList, to file: DownloadsFile) {
        do {
            try file.write(list)
        } catch {
            logger.error("Cannot write downloads: \(error.localizedDescription, privacy: .public)")
        }
    }
}
