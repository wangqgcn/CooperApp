import SwiftUI
import SyncCore

/// 首页：Finder 挂载状态和所有存储桶。打开 App 时先显示这里。
struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let connections = app.connections.connections
        Group {
            if connections.isEmpty {
                WelcomeView()
            } else {
                PageScroll {
                    PageHeader(title: "存储桶", subtitle: subtitle(connections)) {
                        Button {
                            app.addConnection()
                        } label: {
                            Label("添加存储桶", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    MountBanner()
                    BucketTable(connections: connections)
                }
            }
        }
        .navigationTitle("首页")
        .hidesToolbarTitle()
    }

    private func subtitle(_ connections: [Connection]) -> String {
        let scanned = connections.compactMap { app.storage.scans[$0.id] }.filter { !$0.isRunning && $0.error == nil }
        var text = "\(connections.count) 个存储桶"
        if !scanned.isEmpty {
            let total = scanned.reduce(Int64(0)) { $0 + $1.summary.totalBytes }
            text += " · 已统计 \(total.formatted(.byteCount(style: .file)))"
        }
        return text
    }
}

/// Finder 挂载横幅
private struct MountBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.connections
        HStack(spacing: 14) {
            Image(systemName: model.isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(model.isMounted ? Palette.success : Color.accentColor)
                .frame(width: 40, height: 40)
                .background((model.isMounted ? Palette.success : Color.accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isMounted ? "已挂载到 Finder" : "还没有挂载到 Finder")
                    .font(.headline)
                Text(model.isMounted
                     ? "在 Finder 侧栏「位置」里点「\(CooperDrive.sidebarName)」，每个存储桶是其中一个文件夹。"
                     : "挂载后可以像本地文件夹一样在 Finder 里浏览、打开和拖入文件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if model.isMounted {
                Button("在 Finder 中打开") { Task { await model.openInFinder() } }
            } else {
                Button("挂载到 Finder") { Task { await model.mount() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .disabled(model.isBusy)
        .card()
    }
}

/// 存储桶列表：每行一个存储桶，点一下进入
private struct BucketTable: View {
    @Environment(AppModel.self) private var app
    let connections: [Connection]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("名称")
                    .padding(.leading, 50)
                    .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                Text("存储桶")
                    .frame(width: BucketRow.bucketWidth, alignment: .leading)
                Text("Endpoint")
                    .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                Text("占用")
                    .frame(width: BucketRow.usageWidth, alignment: .trailing)
                Color.clear
                    .frame(width: BucketRow.trailingWidth)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)

            ForEach(connections, id: \.id) { connection in
                Divider()
                BucketRow(connection: connection)
            }
        }
        .card(padding: 0)
    }
}

private struct BucketRow: View {
    static let bucketWidth: CGFloat = 150
    static let usageWidth: CGFloat = 110
    static let trailingWidth: CGFloat = 44

    @Environment(AppModel.self) private var app
    let connection: Connection
    @State private var isHovered = false

    var body: some View {
        let provider = connection.storageProvider
        let isMissingKey = app.connections.missingCredentials.contains(connection.id)
        HStack(spacing: 14) {
            Button {
                app.open(connection.id)
            } label: {
                HStack(spacing: 14) {
                    HStack(spacing: 14) {
                        ProviderBadge(provider: provider, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(app.connections.folderNames[connection.id] ?? connection.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                if connection.publicBaseURL != nil {
                                    Image(systemName: "globe")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .help("已配置公开域名：\(connection.publicBaseURL?.absoluteString ?? "")")
                                }
                            }
                            if isMissingKey {
                                Label("缺少访问密钥", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Palette.warning)
                            } else {
                                Text(provider.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)

                    Text(connection.config.bucket)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: Self.bucketWidth, alignment: .leading)
                        .help(connection.config.bucket)

                    Text(connection.endpointHost)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                        .help(connection.config.endpoint.absoluteString)

                    UsageCell(scan: app.storage.scans[connection.id])
                        .frame(width: Self.usageWidth, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开「\(connection.name)」")

            HStack(spacing: 2) {
                Menu {
                    BucketMenuItems(connection: connection)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(isHovered ? 1 : 0.5)
                .help("更多操作")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: Self.trailingWidth, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(isHovered ? Palette.hover : .clear)
        .onHover { isHovered = $0 }
        .contextMenu { BucketMenuItems(connection: connection) }
    }
}

/// 占用一栏：统计过显示大小和对象数，否则显示「未统计」
private struct UsageCell: View {
    let scan: StorageModel.Scan?

    var body: some View {
        if let scan, scan.isRunning {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("统计中")
                    .foregroundStyle(.secondary)
            }
        } else if let scan, scan.summary.objectCount > 0 || scan.finishedAt != nil {
            VStack(alignment: .trailing, spacing: 2) {
                Text(scan.summary.totalBytes.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                Text("\(scan.summary.objectCount.formatted(.number.notation(.compactName))) 个对象")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("未统计")
                .foregroundStyle(.tertiary)
        }
    }
}

/// 一个存储桶都没有时的欢迎页
private struct WelcomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 18) {
            Image("CooperMark")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("欢迎使用 Cooper")
                    .font(.system(size: 28, weight: .semibold))
                Text("连接 Cloudflare R2、Amazon S3 或任何兼容 S3 的存储桶，\n在这里浏览和管理文件，也能直接在 Finder 中打开。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button {
                app.addConnection()
            } label: {
                Label("添加第一个存储桶", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            HStack(spacing: 8) {
                ForEach(StorageProvider.allCases.filter { $0 != .other }) { provider in
                    ProviderBadge(provider: provider, size: 26)
                        .help(provider.displayName)
                }
            }
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.page)
    }
}
