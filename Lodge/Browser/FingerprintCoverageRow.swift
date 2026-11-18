import SwiftUI

/// A row saying what fingerprint protection covers or leaves out: its title, the list under it, both left aligned, the
/// list wrapping. The protection page and Settings both use it, so the two read alike.
struct FingerprintCoverageRow: View {
    let title: LocalizedStringKey
    let list: LocalizedStringKey

    init(_ title: LocalizedStringKey, _ list: LocalizedStringKey) {
        self.title = title
        self.list = list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(list)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
