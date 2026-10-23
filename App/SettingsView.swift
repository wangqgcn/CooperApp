import ServiceManagement
import SwiftUI

/// 设置页：管理存储桶连接、Finder 挂载，以及版本信息。内嵌在主窗口里（⌘, 也会跳到这里）。
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var isConfirmingUnmount = false

    var body: some View {
        let model = app.connections
        PageScroll(maxWidth: 720) {
            PageHeader(title: "设置")

            CardSection(title: "存储桶连接", footer: "访问密钥保存在系统钥匙串里，连接配置本身不含密钥。") {
                ForEach(model.connections, id: \.id) { connection in
                    ConnectionRow(connection: connection)
                    Divider()
                        .padding(.leading, 58)
                }
                Button {
                    app.addConnection()
                } label: {
                    Label("添加存储桶", systemImage: "plus.circle.fill")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            CardSection(title: "Finder 挂载", footer: "卸载会移除 Finder 里的「\(CooperDrive.sidebarName)」和本机缓存的文件，存储桶里的数据不受影响。") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        StatusDot(isOn: model.isMounted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.isMounted ? "\(CooperDrive.displayName) 已挂载" : "\(CooperDrive.displayName) 未挂载")
                                .font(.headline)
                            Text(model.isMounted
                                 ? "Finder 侧栏「位置」→「\(CooperDrive.sidebarName)」，每个存储桶是其中一个文件夹"
                                 : "挂载后可以在 Finder 里直接浏览存储桶")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        if model.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    HStack(spacing: 8) {
                        if model.isMounted {
                            Button("在 Finder 中打开") { Task { await model.openInFinder() } }
                            Button("立即刷新") { Task { await model.refresh() } }
                                .help("立即检查所有存储桶的远端变化")
                            Spacer()
                            Button("卸载…", role: .destructive) { isConfirmingUnmount = true }
                        } else {
                            Button("挂载到 Finder") { Task { await model.mount() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.connections.isEmpty)
                            Spacer()
                        }
                    }
                    .disabled(model.isBusy)
                    if !model.status.isEmpty {
                        Text(model.status)
                            .font(.callout)
                            .foregroundStyle(model.status.hasPrefix("失败") ? .red : .secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
            }

            CardSection(title: "通用", footer: "关掉主窗口后 Cooper 会留在菜单栏里，Finder 挂载照常同步；退出请用菜单栏面板里的「退出 Cooper」。") {
                GeneralSettings()
            }

            CardSection(title: "关于") {
                HStack(spacing: 14) {
                    Image("CooperMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cooper")
                            .font(.headline)
                        Text("版本 \(Self.version)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("把 S3 兼容的存储桶挂载到 Finder 的原生 Mac 客户端")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("设置")
        .hidesToolbarTitle()
        .confirmationDialog("卸载 \(CooperDrive.displayName)？", isPresented: $isConfirmingUnmount) {
            Button("卸载", role: .destructive) { Task { await model.unmount() } }
        } message: {
            Text("Finder 里的「\(CooperDrive.sidebarName)」和本机缓存的文件会被移除，存储桶里的数据不受影响。之后可以随时重新挂载。")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)（\(build)）"
    }
}

private struct ConnectionRow: View {
    @Environment(AppModel.self) private var app
    let connection: Connection

    var body: some View {
        HStack(spacing: 12) {
            ProviderBadge(provider: connection.storageProvider, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.connections.folderNames[connection.id] ?? connection.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(connection.config.bucket) · \(connection.endpointHost)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if app.connections.missingCredentials.contains(connection.id) {
                Label("缺少密钥", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.warning)
            }
            Button("编辑") { app.editConnection(connection.id) }
            Menu {
                BucketMenuItems(connection: connection)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contextMenu { BucketMenuItems(connection: connection) }
    }
}

/// 登录时启动、Dock 图标
private struct GeneralSettings: View {
    @AppStorage(DockIcon.hidesWhenClosedKey) private var hidesDockIcon = true
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSwitch(title: "登录时启动", detail: "登录 Mac 后自动运行，只出现在菜单栏，不打开主窗口", isOn: launchAtLogin)
            if loginItemStatus == .requiresApproval {
                HStack(spacing: 8) {
                    Label("需要在「系统设置 → 通用 → 登录项」里允许 Cooper", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Palette.warning)
                    Spacer(minLength: 8)
                    Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            if let loginItemError {
                Text(loginItemError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            Divider()
                .padding(.leading, 16)
            SettingsSwitch(title: "关闭主窗口后隐藏 Dock 图标", detail: "只保留菜单栏图标，从菜单栏可以重新打开主窗口", isOn: $hidesDockIcon)
        }
        .onAppear { loginItemStatus = SMAppService.mainApp.status }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding {
            loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        } set: { enabled in
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                loginItemError = nil
            } catch {
                loginItemError = "设置失败：\(error.localizedDescription)"
            }
            loginItemStatus = SMAppService.mainApp.status
        }
    }
}

/// 设置卡片里的一行开关：左边标题和说明，右边开关
private struct SettingsSwitch: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
