import Foundation
import UniformTypeIdentifiers

/// Downloads that run code when opened (CWE-451), so Open asks first.
public enum DownloadOpenRisk {
    /// UTType has no constant for installer packages, so they go by identifier.
    private static let types: [UTType] = [.executable, .application, .shellScript, .script, .diskImage]
        + ["com.apple.installer-package-archive", "com.apple.installer-package"].compactMap { UTType($0) }

    private static let extensions: Set<String> = [
        "command", "tool", "sh", "app", "pkg", "mpkg", "dmg", "terminal", "scpt", "workflow", "fileloc", "webloc",
        "inetloc", "jar", "scptd", "applescript", "action", "prefpane", "saver", "kext", "plugin", "bundle",
    ]

    /// Whether `fileName` (by its extension) or the file's `contentType` is an app, script, installer or disk image.
    public static func isAppOrScript(fileName: String, contentType: UTType? = nil) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        let candidates = [contentType, ext.isEmpty ? nil : UTType(filenameExtension: ext)].compactMap { $0 }
        return candidates.contains { type in types.contains { type.conforms(to: $0) } }
    }

    public static func confirmation(for fileName: String) -> String {
        "“\(fileName)” is an app or script. Open it anyway?"
    }
}
