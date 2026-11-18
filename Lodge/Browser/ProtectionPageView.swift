import LodgeKit
import SwiftUI

/// The fingerprint protection page at `lodge://protection` (D5): what the protection does and where it stops, the site
/// the indicator opened it for with its switch, and every site turned off in this workspace with theirs. A switch
/// records the exception (D7) and reloads that site's tabs at once; nothing ever asks. In Anonymous each tab keeps its
/// own exceptions, so the page speaks of the tab it was opened from, and lists that tab's; opened otherwise it lists none.
struct ProtectionPageView: View {
    let model: BrowserModel
    /// The page's own tab, whose target it shows.
    let page: TabID

    /// Absent when the page was reached by its address or the tab it was opened from has closed: no "This site".
    private var target: ProtectionTarget? { model.protectionTarget(for: page) }
    /// Whose exceptions the page lists and switches: the workspace's, or in Anonymous the target tab's store.
    private var store: StoreRef? { model.isAnonymous ? target?.store : model.store }
    private var settings: FingerprintSettings? { store.flatMap(model.fingerprintSettings(on:)) }

    var body: some View {
        // The page scrolls rather than the form, as in Settings.
        ScrollView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Fingerprint protection")
                            .font(.title2.weight(.semibold))
                        Text(model.isAnonymous ? anonymousSummary : summary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                if let target, let store, let settings {
                    thisSite(target, store: store, settings: settings)
                }
                if let store, let settings {
                    turnedOff(store: store, settings: settings)
                }
                Section("What it covers") {
                    FingerprintCoverageRow("Covered", "Images drawn on a canvas, WebGL and audio")
                    FingerprintCoverageRow(
                        "Not covered",
                        "Your IP address, code a site runs in web or service workers, the TLS handshake and header order")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        // As Settings': an always-shown scroller would draw an opaque track over the page.
        .scrollIndicators(.never)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var summary: String {
        String(localized: "Sites can tell devices apart by how they draw images and play sound. In this workspace, Lodge gives each site its own answers, the same on every visit, so a site can't recognize you across workspaces.")
    }

    private var anonymousSummary: String {
        String(localized: "Sites can tell devices apart by how they draw images and play sound. Each Anonymous tab gets its own answers, gone with the tab.")
    }

    private func thisSite(_ target: ProtectionTarget, store: StoreRef, settings: FingerprintSettings) -> some View {
        Section {
            Text(verbatim: target.site)
                .font(.headline)
            Toggle("Protect", isOn: protects(target.site, on: store, settings))
            if let read = read(target) {
                Text("Read: \(read)")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("This site")
        } footer: {
            Text(
                model.isAnonymous
                    ? LocalizedStringKey("Switching it reloads this site in this tab.")
                    : LocalizedStringKey("Switching it reloads this site's tabs in this workspace.")
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func turnedOff(store: StoreRef, settings: FingerprintSettings) -> some View {
        Section(
            model.isAnonymous
                ? LocalizedStringKey("Turned off in this tab") : LocalizedStringKey("Turned off in this workspace")
        ) {
            if settings.offSites.isEmpty {
                Text(
                    model.isAnonymous
                        ? LocalizedStringKey("Every site is protected in this tab.")
                        : LocalizedStringKey("Every site is protected in this workspace.")
                )
                .foregroundStyle(.secondary)
            } else {
                ForEach(settings.offSites.sorted(), id: \.self) { site in
                    Toggle(isOn: protects(site, on: store, settings)) {
                        Text(verbatim: site)
                    }
                }
            }
        }
    }

    /// On while `site` is protected; switching it records the exception and reloads that site's tabs.
    private func protects(_ site: String, on store: StoreRef, _ settings: FingerprintSettings) -> Binding<Bool> {
        Binding(
            get: { !settings.isOff(site) },
            set: { model.setFingerprintProtection($0, for: site, on: store) })
    }

    /// What the target tab's page read, in a fixed order, while that tab is still at the site; nil for nothing.
    private func read(_ target: ProtectionTarget) -> String? {
        guard model.fingerprintSite(target.tab) == target.site, let reads = model.fingerprintReads[target.tab]
        else { return nil }
        let names = FingerprintAPI.allOrdered.filter(reads.contains).map(\.readName)
        return names.isEmpty ? nil : names.joined(separator: String(localized: ", "))
    }
}

extension FingerprintAPI {
    fileprivate static let allOrdered: [FingerprintAPI] = [.canvas, .webgl, .audio]

    /// How the page names what a site read: "canvas", "WebGL", "audio".
    fileprivate var readName: String {
        switch self {
        case .canvas: String(localized: "canvas")
        case .webgl: String(localized: "WebGL")
        case .audio: String(localized: "audio")
        }
    }
}
