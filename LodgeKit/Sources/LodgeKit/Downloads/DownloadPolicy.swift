import Foundation

/// Which navigation responses become downloads instead of pages.
public enum DownloadPolicy {
    /// A response the web view cannot show is always a download; a main-frame response is one too when its
    /// `Content-Disposition` is `attachment` (the type before any `;` parameters, ignoring case and spaces).
    public static func shouldDownload(mimeCanShow: Bool, contentDisposition: String?, isMainFrame: Bool) -> Bool {
        guard mimeCanShow else { return true }
        guard isMainFrame, let contentDisposition else { return false }
        let type = contentDisposition.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        return type.lowercased() == "attachment"
    }
}
