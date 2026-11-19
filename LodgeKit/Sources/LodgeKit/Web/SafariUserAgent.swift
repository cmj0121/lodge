import Foundation

/// What Lodge adds to WebKit's User-Agent so sites treat its pages as Safari's (D1): sites such as YouTube follow the
/// system's dark appearance only for a browser they recognise.
public enum SafariUserAgent {
    /// The Safari version named when the installed Safari's cannot be read.
    public static let fallbackVersion = "18.0"

    /// `Version/<v> Safari/605.1.15`, naming `safariVersion` when it is a plain dotted number and the fallback
    /// otherwise.
    public static func applicationName(safariVersion: String?) -> String {
        let version = safariVersion.flatMap { $0.wholeMatch(of: /[0-9]+(\.[0-9]+)*/) != nil ? $0 : nil }
        return "Version/\(version ?? fallbackVersion) Safari/605.1.15"
    }
}
