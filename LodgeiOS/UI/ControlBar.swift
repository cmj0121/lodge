import LodgeKit
import SwiftUI
import WebKit

/// A row of chrome over the page: its glass pieces are siblings in one container, so they blend as they move.
/// The row sets no frame of its own; the layout around it decides where it floats and how wide it is.
struct ControlBar<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) { content }
        }
    }
}

extension View {
    /// The glass a piece of chrome sits on: a capsule that answers touch.
    func controlGlass() -> some View {
        glassEffect(.regular.interactive(), in: .capsule)
    }

    /// One control in a row of equal slots: the icon centred in a share of the width, the whole slot tappable.
    func controlSlot() -> some View {
        labelStyle(.iconOnly)
            .font(.system(size: 19, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(.rect)
    }
}

struct BackButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tab = model.selectedTab
        Button("Back", systemImage: "chevron.backward") { model.currentView?.goBack() }
            .disabled(tab?.canGoBack != true)
    }
}

struct ForwardButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tab = model.selectedTab
        Button("Forward", systemImage: "chevron.forward") { model.currentView?.goForward() }
            .disabled(tab?.canGoForward != true)
    }
}

struct NavigationButtons: View {
    var body: some View {
        HStack(spacing: 20) {
            BackButton()
            ForwardButton()
        }
        .labelStyle(.iconOnly)
    }
}

/// Opens the tabs; the number of open tabs sits inside the front square, and is left out when there are none.
struct TabsButton: View {
    @Environment(AppModel.self) private var model
    let action: () -> Void

    var body: some View {
        let count = model.activeTabs.count
        Button(action: action) {
            Label {
                Text("Tabs")
            } icon: {
                Image(systemName: "square.on.square")
                    .overlay {
                        if count > 0 {
                            GeometryReader { glyph in
                                Text(count, format: .number)
                                    .font(.system(size: glyph.size.width * 0.4, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .minimumScaleFactor(0.6)
                                    .lineLimit(1)
                                    .frame(width: glyph.size.width * 0.42)
                                    // The centre of the front square, as a share of the symbol's frame.
                                    .position(x: glyph.size.width * 0.59, y: glyph.size.height * 0.6)
                            }
                        }
                    }
            }
        }
        .accessibilityValue(Text(count, format: .number))
    }
}

extension AppModel {
    /// The selected tab's web view, when it has one.
    var currentView: WKWebView? {
        guard let tab = selectedTab, pool.hasView(tab.id) else { return nil }
        return pool.view(for: tab.id)
    }
}
