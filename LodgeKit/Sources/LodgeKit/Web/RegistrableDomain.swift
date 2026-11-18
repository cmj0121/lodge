import Foundation
import TLDExtractSwift

/// The registrable domain (eTLD+1) of a web URL, by the Public Suffix List frozen into the package:
/// Lodge never fetches the live list (D2).
public enum RegistrableDomain {
    /// Built on first use from the frozen list, which always parses; read-only after init, so shared.
    nonisolated(unsafe) private static let extractor = try! TLDExtract(useFrozenData: true)

    /// The lower-cased eTLD+1 of an http(s) URL; an IP host, or a host with no public suffix
    /// (`localhost`), is its own domain. Nil for any other scheme or a URL without a host.
    public static func of(_ url: URL) -> String? {
        guard Origin.isWeb(url), let host = url.host()?.lowercased() else { return nil }
        if IPHost(host) != nil { return host }
        return extractor.parse(host)?.rootDomain?.lowercased() ?? host
    }
}
