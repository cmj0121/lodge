import AppKit
import LodgeKit
import UniformTypeIdentifiers

/// The Bookmarks menu's Import and Export: the file panels and the alerts for what goes wrong. Reading and
/// writing the file are the model's (`importBookmarks(from:)`, `exportBookmarks(to:)`).
@MainActor
enum BookmarkTransfer {
    /// Asks for one bookmark HTML file, then adds it to the bookmarks as a folder named after the file, with a
    /// progress sheet on the window meanwhile. Its Cancel cancels the import and closes the sheet at once, without
    /// waiting for a parse already under way: that result is dropped and no alert follows. Once the folder has been
    /// added, Cancel only closes the sheet. The panel, the sheet and any alert all use the window key at the start.
    static func importBookmarks(into model: BrowserModel) {
        guard !model.isImportingBookmarks else { return }
        let window = window
        let panel = NSOpenPanel()
        panel.message = "Choose a bookmark file exported from a browser."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        present(panel, on: window) { url in
            // On the next turn, so the progress sheet does not start while the panel's is still ending.
            Task {
                let task = Task { try await model.importBookmarks(from: url) }
                // The model clears the flag on the turn it adds the folder, so a later Cancel cannot hide it.
                let progress = window.map {
                    ImportProgress(on: $0) { if model.isImportingBookmarks { task.cancel() } }
                }
                let result = await task.result
                progress?.dismiss()
                guard !task.isCancelled, case .failure(let error) = result, !(error is CancellationError) else {
                    return
                }
                show(importAlert(for: error, file: url.lastPathComponent), on: window)
            }
        }
    }

    /// Asks where to save, then writes every bookmark there as one bookmark HTML file.
    static func exportBookmarks(from model: BrowserModel) {
        let panel = NSSavePanel()
        panel.message = "Other browsers can import this file."
        panel.prompt = "Export"
        panel.nameFieldStringValue = "Lodge Bookmarks.html"
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        let window = window
        present(panel, on: window) { url in
            // On the next turn, so an alert's sheet does not start while the panel's is still ending.
            Task {
                do {
                    try model.exportBookmarks(to: url)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "The bookmarks could not be exported."
                    alert.informativeText = error.localizedDescription
                    show(alert, on: window)
                }
            }
        }
    }

    private static func importAlert(for error: Error, file: String) -> NSAlert {
        let alert = NSAlert()
        switch error {
        case BookmarkFile.ReadError.tooLarge:
            alert.messageText = "“\(file)” is too large to import."
            alert.informativeText = "Bookmark files larger than 5 MB are not imported."
        case NetscapeBookmarks.ImportError.notABookmarkFile:
            alert.messageText = "“\(file)” is not a bookmark file."
            alert.informativeText =
                "Export the bookmarks from the other browser as an HTML file, then import that file."
        case NetscapeBookmarks.ImportError.tooManyBookmarks(let limit):
            alert.messageText = "“\(file)” has too many bookmarks to import."
            alert.informativeText =
                "Bookmark files with more than \(limit.formatted()) bookmarks are not imported. Nothing was added."
        case NetscapeBookmarks.ImportError.tooComplex:
            alert.messageText = "“\(file)” has too many tags to import."
            alert.informativeText =
                "The file has more than \(NetscapeBookmarks.maxElements.formatted()) tags, too many for a browser’s "
                + "bookmark export. Nothing was added."
        default:
            alert.messageText = "“\(file)” could not be read."
            alert.informativeText = "Check that the file still exists and is a text file."
        }
        return alert
    }

    private static var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    /// Runs the panel as a sheet on `window`, or modal when there is none, and hands on the chosen file.
    private static func present(_ panel: NSSavePanel, on window: NSWindow?, then handle: @escaping (URL) -> Void) {
        let finish = { (response: NSApplication.ModalResponse) in
            if response == .OK, let url = panel.url { handle(url) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Shows the alert as a sheet on `window`, or modal when there is none.
    private static func show(_ alert: NSAlert, on window: NSWindow?) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

/// The sheet an import shows while it runs: "Importing Bookmarks…", a spinner and a Cancel button.
@MainActor
private final class ImportProgress: NSObject {
    private let sheet: NSPanel
    private weak var window: NSWindow?
    private let cancel: () -> Void

    /// Begins the sheet on `window`; Cancel (or Escape) runs `cancel` and closes it.
    init(on window: NSWindow, cancel: @escaping () -> Void) {
        sheet = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        self.window = window
        self.cancel = cancel
        super.init()

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Importing Bookmarks…")
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancelImport))
        button.keyEquivalent = "\u{1b}"

        let status = NSStackView(views: [spinner, label])
        status.spacing = 8
        let content = NSStackView(views: [status, button])
        content.orientation = .vertical
        content.alignment = .trailing
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20).isActive = true
        sheet.contentView = content
        window.beginSheet(sheet)
    }

    /// Closes the sheet; nothing when it is already closed.
    func dismiss() {
        guard let window, sheet.sheetParent != nil else { return }
        window.endSheet(sheet)
    }

    @objc private func cancelImport() {
        cancel()
        dismiss()
    }
}
