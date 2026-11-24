import LodgeKit
import SwiftUI

/// iPad (regular width): a sidebar beside the page, as on the Mac. iPhone (compact width): the page full screen, with
/// the address field above it, the controls below it in reach of a thumb, and the tabs in a sheet.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var model = model
        Group {
            if sizeClass == .regular {
                SplitLayout()
            } else {
                CompactLayout()
            }
        }
        .tint(model.active.color?.tint)
        .preferredColorScheme(model.active.appearance.colorScheme)
        .sheet(isPresented: $model.showsSettings) { SettingsSheet() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) {
            _ in model.didReceiveMemoryWarning()
        }
    }
}

/// iPad: workspaces, pins and tabs in the sidebar; the page and its toolbar beside it.
private struct SplitLayout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            TabsPanel()
                .navigationTitle(model.active.name)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { WorkspaceMenu() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Tab", systemImage: "plus") { model.newTab() }
                    }
                }
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    NavigationButtons()
                    AddressField()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                LoadProgress()
                PageView()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// iPhone: the address field above the page, and one glass capsule of controls floating over its foot, in reach of a
/// thumb. The page scrolls under the capsule but ends above it.
private struct CompactLayout: View {
    @Environment(AppModel.self) private var model
    @State private var showsTabs = false
    @State private var barHeight: CGFloat = 0
    @State private var bottomSafeArea: CGFloat = 0

    var body: some View {
        PageView(obscuredBottom: barHeight + Self.barGap + bottomSafeArea)
            .overlay(alignment: .bottom) {
                ControlBar {
                    HStack(spacing: 0) {
                        BackButton().controlSlot()
                        ForwardButton().controlSlot()
                        Button("New Tab", systemImage: "plus") { model.newTab() }.controlSlot()
                        TabsButton { showsTabs = true }.controlSlot()
                        WorkspaceMenu().controlSlot()
                    }
                    .padding(.horizontal, 6)
                    .controlGlass()
                }
                .padding(.horizontal, 16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                .padding(.bottom, Self.barGap)
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomSafeArea = $0 }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 6) {
                    ControlBar { AddressField() }
                        .padding(.horizontal)
                    LoadProgress()
                }
                .padding(.top, 4)
            }
            .sheet(isPresented: $showsTabs) {
                NavigationStack {
                    TabsPanel { showsTabs = false }
                        .navigationTitle(model.active.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) { WorkspaceMenu() }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showsTabs = false }
                            }
                            ToolbarItem(placement: .bottomBar) {
                                Button("New Tab", systemImage: "plus") {
                                    model.newTab()
                                    showsTabs = false
                                }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
    }

    /// The space between the capsule and the home indicator.
    private static let barGap: CGFloat = 4
}

/// The selected tab's page, or the start page for a blank tab (or none).
struct PageView: View {
    @Environment(AppModel.self) private var model
    /// How far up from its foot floating chrome covers the page.
    var obscuredBottom: CGFloat = 0

    var body: some View {
        if let tab = model.selectedTab, tab.url != nil || tab.isLive {
            WebViewHost(tab: tab.id, pool: model.pool, obscuredBottom: obscuredBottom)
                .id(tab.id)
                .ignoresSafeArea(.container, edges: .bottom)
        } else if obscuredBottom > 0 {
            StartPage()
                .safeAreaPadding(.bottom, obscuredBottom)
                .ignoresSafeArea(.container, edges: .bottom)
        } else {
            StartPage()
        }
    }
}

/// A thin bar under the address while the page loads.
struct LoadProgress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tab = model.selectedTab
        ProgressView(value: tab.flatMap { model.progress[$0.id] } ?? 0)
            .progressViewStyle(.linear)
            .frame(height: 2)
            .opacity(tab?.isLoading == true ? 1 : 0)
            .animation(.default, value: tab?.isLoading)
    }
}

extension WorkspaceColor {
    var tint: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .graphite: .gray
        }
    }
}

extension WorkspaceAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
