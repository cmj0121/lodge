import Foundation

/// Which URLs another app may open in Lodge (D7): web pages only, http or https with a host. Anything else
/// (`file:`, `javascript:`, `mailto:`, a custom scheme) is ignored.
public enum ExternalLink {
    public static func accepts(_ url: URL) -> Bool { Origin.isWeb(url) }

    /// The URLs Lodge opens, in the order they came, and how many it ignores.
    public static func filter(_ urls: [URL]) -> (accepted: [URL], ignored: Int) {
        let accepted = urls.filter(accepts)
        return (accepted, urls.count - accepted.count)
    }
}
