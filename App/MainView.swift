import SwiftUI

/// 主窗口：左边是首页、存储桶和设置，右边是选中的页面。
struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
        }
        .sheet(item: $app.editor) { _ in
            ConnectionEditorSheet()
        }
        .confirmationDialog(removalTitle, isPresented: isConfirmingRemoval, presenting: app.removalCandidate) { connection in
            Button("移除", role: .destructive) {
                Task { await app.connections.delete(id: connection.id) }
            }
        } message: { _ in
            Text("CooperDrive 里对应的文件夹和本机缓存会被移除，存储桶里的数据不受影响。")
        }
        .onChange(of: app.connections.connections) { app.fixSelection() }
        .onAppear {
            DockIcon.show()
            // 作为登录项启动时只留在菜单栏
            if app.launchedAtLogin {
                app.launchedAtLogin = false
                dismissWindow(id: "main")
            }
        }
        .onDisappear { DockIcon.mainWindowClosed() }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.selection {
        case .bucket(let id):
            if let connection = app.connections.connections.first(where: { $0.id == id }) {
                if let browser = app.browser(for: connection) {
                    BrowserView(browser: browser)
                        .id(id)
                } else {
                    ContentUnavailableView {
                        Label("缺少访问密钥", systemImage: "key")
                    } description: {
                        Text("钥匙串里没有这个存储桶的密钥，请重新填写。")
                    } actions: {
                        Button("编辑连接…") { app.editConnection(id) }
                    }
                    .navigationTitle(app.connections.folderNames[id] ?? connection.name)
                }
            }
        case .storage:
            DashboardView()
        case .transfers:
            TransfersView()
        case .settings:
            SettingsView()
        case .home, nil:
            HomeView()
        }
    }

    private var removalTitle: String {
        guard let connection = app.removalCandidate else { return "" }
        return "移除「\(app.connections.folderNames[connection.id] ?? connection.name)」？"
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(get: { app.removalCandidate != nil }, set: { if !$0 { app.removalCandidate = nil } })
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            // App 标志就是首页入口，选中时整行高亮
            Section {
                HStack(spacing: 10) {
                    Image("CooperMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    Text("Cooper")
                        .font(.title3.weight(.semibold))
                }
                .padding(.vertical, 4)
                .tag(SidebarItem.home)
                .help("首页")
                .accessibilityLabel("首页")
            }
            Section {
                ForEach(app.connections.connections, id: \.id) { connection in
                    Label {
                        Text(app.connections.folderNames[connection.id] ?? connection.name)
                    } icon: {
                        ProviderBadge(provider: connection.storageProvider, size: 18)
                    }
                    .tag(SidebarItem.bucket(connection.id))
                    .contextMenu { BucketMenuItems(connection: connection) }
                }
            } header: {
                HStack {
                    Text("存储桶")
                    Spacer()
                    Button {
                        app.addConnection()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("添加存储桶")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        .sidebarFooter {
            SidebarFooter()
        }
    }
}

private extension View {
    /// 固定在侧栏底部的内容。macOS 26 起用 safeAreaBar，列表滚到下面时有系统的边缘渐隐
    @ViewBuilder
    func sidebarFooter(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: content)
        }
    }
}

/// 侧栏左下角固定的「传输」和「设置」
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 2) {
            SidebarFooterRow(title: "传输", systemImage: "arrow.up.arrow.down", item: .transfers, badge: app.transfers.activeCount)
            SidebarFooterRow(title: "设置", systemImage: "gearshape", item: .settings)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// 侧栏样式的一行：图标 + 文字，选中时灰色圆角底。不在 List 里，选中它时 List 的选中会自然消失
private struct SidebarFooterRow: View {
    @Environment(AppModel.self) private var app
    let title: String
    let systemImage: String
    let item: SidebarItem
    var badge = 0
    @State private var isHovered = false

    var body: some View {
        let isSelected = app.selection == item
        Button {
            app.selection = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                Text(title)
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(background(isSelected: isSelected), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func background(isSelected: Bool) -> Color {
        if isSelected { return Palette.sidebarSelection }
        return isHovered ? Palette.hover : .clear
    }
}

/// 存储桶的右键菜单，侧栏、首页和设置页共用
struct BucketMenuItems: View {
    @Environment(AppModel.self) private var app
    let connection: Connection

    var body: some View {
        Button("打开") { app.open(connection.id) }
        Button("在 Finder 中打开") { Task { await app.connections.openInFinder(connectionID: connection.id) } }
            .disabled(!app.connections.isMounted)
        Button("查看存储占用") { app.showStorage(of: connection.id) }
        Divider()
        Button("编辑连接…") { app.editConnection(connection.id) }
        Button("复制连接…") { app.duplicateConnection(connection.id) }
        Button("移除…", role: .destructive) { app.removalCandidate = connection }
    }
}
