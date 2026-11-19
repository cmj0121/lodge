import SwiftUI

/// Shown in place of a tab's page when its main frame was about to load a plain-http page (D8): the connection to
/// `host` is not encrypted, with Go Back (the default: nothing was sent, the page stays as it was) and Continue (the
/// host is allowed in this workspace until Lodge quits, or in Anonymous in this tab and its popups until they close,
/// and the page loads). One centred column a little above the middle, on the window's ground: an open lock, the title
/// and why it matters, then one way forward made obvious — Go Back — with Continue quieter beneath it and what
/// Continue remembers right under it.
struct InsecurePageView: View {
    let host: String
    let isAnonymous: Bool
    let goBack: () -> Void
    let proceed: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 32)
                content
                Spacer(minLength: 32)
                // A second spacer below lifts the column to the optical centre, a little above the middle.
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .containerRelativeFrame(.vertical)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var content: some View {
        VStack(spacing: 28) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 68, height: 68)
                .background(Circle().fill(Color.orange.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("The connection to \(host) is not encrypted")
                    .font(.title2.weight(.semibold))
                Text("What you send to this site or see on it, such as passwords and messages, can be read or changed on the way.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 520)
            VStack(spacing: 10) {
                Button(action: goBack) {
                    Text("Go Back").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button(action: proceed) {
                    Text("Continue to \(host)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .padding(.top, 4)
                Text(
                    isAnonymous
                        ? LocalizedStringKey("If you continue, this tab and its popups won't ask again for this site until they close.")
                        : LocalizedStringKey("If you continue, this workspace won't ask again for this site until Lodge quits.")
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 260)
        }
    }
}
