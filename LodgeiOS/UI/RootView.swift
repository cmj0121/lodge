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

/// iPhone: the address field, the page, then a row of controls under it.
private struct CompactLayout: View {
    @Environment(AppModel.self) private var model
    @State private var showsTabs = false

    var body: some View {
        PageView()
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 6) {
                    AddressField()
                        .padding(.horizontal)
                    LoadProgress()
                }
                .padding(.top, 4)
                .background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    HStack {
                        NavigationButtons()
                        Spacer()
                        Button("New Tab", systemImage: "plus") { model.newTab() }
                        Spacer()
                        Button {
                            showsTabs = true
                        } label: {
                            Label("Tabs", systemImage: "square.on.square")
                                .overlay(alignment: .center) {
                                    Text(model.activeTabs.count, format: .number)
                                        .font(.caption2.bold())
                                        .offset(x: 2, y: 2)
                                }
                        }
                        Spacer()
                        WorkspaceMenu()
                    }
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
                    .padding(.horizontal, 24)
                }
                .padding(.vertical, 8)
                .background(.bar)
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
}

/// The selected tab's page, or the start page for a blank tab (or none).
struct PageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let tab = model.selectedTab, tab.url != nil || tab.isLive {
            WebViewHost(tab: tab.id, pool: model.pool)
                .id(tab.id)
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

struct NavigationButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tab = model.selectedTab
        let view = tab.flatMap { model.pool.hasView($0.id) ? model.pool.view(for: $0.id) : nil }
        HStack(spacing: 20) {
            Button("Back", systemImage: "chevron.backward") { view?.goBack() }
                .disabled(tab?.canGoBack != true)
            Button("Forward", systemImage: "chevron.forward") { view?.goForward() }
                .disabled(tab?.canGoForward != true)
        }
        .labelStyle(.iconOnly)
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
