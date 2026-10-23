import AppKit
import SwiftUI
import SyncCore

/// 菜单栏面板：挂载状态、整体进度，以及 Finder 和主窗口里改动存储桶的操作记录
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()
            Divider()
            PanelContent()
                .frame(maxHeight: .infinity)
            Divider()
            PanelFooter()
        }
        .frame(width: 360, height: 520)
        // 每次打开都重读一次，不只依赖目录监听
        .onAppear { app.activity.reload() }
    }
}

extension AppModel {
    /// 现存连接的 id。移除了的存储桶的记录不显示
    var connectionIDs: Set<String> {
        Set(connections.connections.map(\.id))
    }

    /// 存储桶在 CooperDrive 里的文件夹名
    func bucketName(_ connectionID: String) -> String {
        connections.folderNames[connectionID] ?? "存储桶"
    }
}

// MARK: - 顶部

private struct PanelHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    /// Finder 一侧的上传总进度，挂载后才有
    @State private var finderUploads: Progress?

    var body: some View {
        let model = app.connections
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image("CooperMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cooper")
                        .font(.headline)
                    status
                }
                Spacer(minLength: 8)
                if model.isMounted {
                    PanelIconButton(systemImage: "folder", help: "在 Finder 中打开") {
                        Task { await model.openInFinder() }
                    }
                }
                moreMenu
            }
            if model.isMounted && runningCount > 0 {
                // Progress 不会通知 SwiftUI，定时读取
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    if let fraction = uploadFraction() {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .task(id: model.isMounted) {
            finderUploads = model.isMounted ? MountManager.globalProgress(for: .uploading) : nil
        }
    }

    private var runningCount: Int {
        app.activity.runningCount(connectionIDs: app.connectionIDs)
    }

    @ViewBuilder
    private var status: some View {
        let model = app.connections
        let failures = app.activity.recentAttentionCount(connectionIDs: app.connectionIDs)
        if model.connections.isEmpty {
            Text("还没有存储桶")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !model.isMounted {
            Text("Finder 挂载未开启")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if runningCount > 0 {
            Text("正在同步 \(runningCount) 项")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if failures > 0 {
            Button {
                app.activity.filter = .attention
            } label: {
                Label("\(failures) 项操作失败", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Palette.warning)
            }
            .buttonStyle(.plain)
            .help("只看失败的操作")
        } else {
            HStack(spacing: 6) {
                StatusDot(isOn: true)
                Text("已挂载 · \(model.connections.count) 个存储桶")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if app.connections.isMounted {
                Button("立即刷新") { Task { await app.connections.refresh() } }
            }
            Button("打开 Cooper") { openWindow.showMainWindow() }
            Button("设置…") {
                openWindow.showMainWindow()
                app.selection = .settings
            }
            Divider()
            Button("清除记录") { app.activity.clear() }
                .disabled(app.activity.events.isEmpty)
            Divider()
            Button("退出 Cooper") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    /// Finder 和主窗口里所有进行中上传的总进度，没有可用数字时返回 nil
    private func uploadFraction() -> Double? {
        var completed = 0.0
        var total = 0.0
        if let finder = finderUploads, !finder.isFinished, finder.totalUnitCount > 0 {
            completed += Double(finder.completedUnitCount)
            total += Double(finder.totalUnitCount)
        }
        for transfer in app.transfers.transfers where transfer.direction == .upload && transfer.state == .running {
            completed += Double(transfer.progress.completedUnitCount)
            total += Double(transfer.progress.totalUnitCount)
        }
        return total > 0 ? min(completed / total, 1) : nil
    }
}

/// 面板里的小图标按钮，悬停时有浅色底
private struct PanelIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 26, height: 26)
                .background(isHovered ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - 中间

private struct PanelContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let model = app.connections
        if model.connections.isEmpty {
            PanelMessage(symbol: "externaldrive.badge.plus", title: "还没有存储桶", detail: "添加一个 S3 兼容的存储桶，就能在 Finder 里直接使用。") {
                Button("添加存储桶…") {
                    openWindow.showMainWindow()
                    app.addConnection()
                }
                .buttonStyle(.borderedProminent)
            }
        } else if !model.isMounted {
            PanelMessage(symbol: "externaldrive", title: "Finder 挂载未开启", detail: "挂载后，在 Finder 里对存储桶的上传、改名、删除都会记录在这里。") {
                Button("挂载到 Finder") { Task { await model.mount() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
            }
        } else {
            VStack(spacing: 0) {
                FilterBar()
                ActivityList()
            }
        }
    }
}

/// 空白时的说明：图标、标题、说明和一个按钮
private struct PanelMessage<Action: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action
                .padding(.top, 4)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PanelMessage where Action == EmptyView {
    init(symbol: String, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

/// 全部 / 进行中 / 失败，右边选存储桶
private struct FilterBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var activity = app.activity
        let ids = app.connectionIDs
        HStack(spacing: 6) {
            ForEach(ActivityModel.Filter.allCases, id: \.self) { filter in
                FilterChip(
                    title: filter.title,
                    count: count(filter, ids: ids),
                    isWarning: filter == .attention,
                    isSelected: activity.filter == filter
                ) {
                    activity.filter = filter
                }
            }
            Spacer(minLength: 6)
            if app.connections.connections.count > 1 {
                Menu {
                    Picker("存储桶", selection: $activity.bucketFilter) {
                        Text("所有存储桶").tag(String?.none)
                        Divider()
                        ForEach(app.connections.connections, id: \.id) { connection in
                            Text(app.bucketName(connection.id)).tag(Optional(connection.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(bucketTitle)
                        .font(.callout)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("只看某个存储桶")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bucketTitle: String {
        guard let id = app.activity.bucketFilter, app.connectionIDs.contains(id) else { return "所有存储桶" }
        return app.bucketName(id)
    }

    private func count(_ filter: ActivityModel.Filter, ids: Set<String>) -> Int {
        switch filter {
        case .all: 0
        case .running: app.activity.runningCount(connectionIDs: ids)
        case .attention: app.activity.attentionCount(connectionIDs: ids)
        }
    }
}

private struct FilterChip: View {
    let title: String
    let count: Int
    let isWarning: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(countColor)
                }
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(isSelected ? Color.accentColor : Palette.field, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var countColor: Color {
        if isSelected { return .white.opacity(0.85) }
        return isWarning ? Palette.warning : .secondary
    }
}

private extension ActivitySection.Period {
    var title: String {
        switch self {
        case .today: "今天"
        case .yesterday: "昨天"
        case .pastWeek: "过去 7 天"
        case .earlier: "更早"
        }
    }
}

private struct ActivityList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 定时刷新「3 分钟前」这类相对时间和分段
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let sections = app.activity.sections(connectionIDs: app.connectionIDs, now: context.date)
            if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.period.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 18)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            ForEach(section.rows) { row in
                                ActivityRowView(row: row)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch app.activity.filter {
        case .all:
            PanelMessage(
                symbol: "clock.arrow.circlepath",
                title: "还没有文件操作",
                detail: "在 Finder 的「\(CooperDrive.sidebarName)」里拖入、改名或删除文件，或在 Cooper 里上传，记录会显示在这里。"
            ) {
                Button("在 Finder 中打开") { Task { await app.connections.openInFinder() } }
            }
        case .running:
            PanelMessage(symbol: "checkmark.circle", title: "没有进行中的操作", detail: "上传、改名、删除进行时会显示在这里。")
        case .attention:
            PanelMessage(symbol: "checkmark.circle", title: "没有失败的操作", detail: "失败的操作会显示原因，系统会自动重试。")
        }
    }
}

// MARK: - 一行记录

private struct ActivityRowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    let row: ActivityRow
    @State private var isHovered = false
    @State private var isExpanded = false

    /// 展开时最多列出这么多条
    private static let detailLimit = 50

    var body: some View {
        let event = row.primary
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                ActivityIcon(event: event, isGroup: row.kind != .single)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(subtitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if event.source == .app {
                            SourceTag()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if row.kind == .single, let reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Palette.warning)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                trailing
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isHovered ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { primaryAction() }
            .contextMenu { menuItems }
            .help(helpText)

            if isExpanded {
                let details = detailEvents
                ForEach(details.prefix(Self.detailLimit)) { detail in
                    ActivityDetailRow(event: detail, prefix: row.kind == .folder ? event.key : nil)
                }
                if details.count > Self.detailLimit {
                    Text("还有 \(details.count - Self.detailLimit) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 48)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: 文字

    private var title: String {
        let event = row.primary
        switch row.kind {
        case .folder:
            return event.name
        case .batch where row.isRepeatedUpdate:
            return displayName(event)
        case .batch:
            return ActivityText.batchTitle(action: event.action, events: row.events)
        case .single:
            if let previousName = event.previousName, previousName != event.name {
                return "\(previousName) → \(event.name)"
            }
            return displayName(event)
        }
    }

    private var subtitle: String {
        let event = row.primary
        let time = row.date.friendlyDescription
        let location = location(of: event)
        switch row.kind {
        case .folder:
            let size = row.totalSize > 0 ? "，\(row.totalSize.formatted(.byteCount(style: .file)))" : ""
            return "上传文件夹 · \(row.fileCount) 个文件\(size) · \(time) · \(location)"
        case .batch where row.isRepeatedUpdate:
            return "修改了 \(row.events.count) 次 · \(time) · \(location)"
        case .batch:
            return event.action == .move ? "\(time) · 移到 \(location)" : "\(time) · \(location)"
        case .single:
            var parts = [ActivityText.status(of: event, location: location)]
            if event.status == .done, [.upload, .update].contains(event.action), let size = event.size, size > 0 {
                parts.append(size.formatted(.byteCount(style: .file)))
            }
            if !event.status.isRunning {
                parts.append(time)
            }
            if event.action != .move {
                parts.append(location)
            }
            return parts.joined(separator: " · ")
        }
    }

    /// 失败原因，系统重试过的话加上次数
    private var reason: String? {
        let event = row.primary
        let retries = event.attempts > 1 ? "（已尝试 \(event.attempts) 次）" : ""
        switch event.status {
        case .failed(let message): return message + retries
        case .interrupted: return "Cooper 或系统中途结束了这次操作" + retries
        default: return nil
        }
    }

    private var helpText: String {
        let event = row.primary
        let path = event.key.isEmpty ? app.bucketName(event.connectionID) : "\(app.bucketName(event.connectionID)) / \(event.key)"
        return "\(path)\n\(event.source == .finder ? "在 Finder 中操作" : "在 Cooper 中操作")"
    }

    private func displayName(_ event: ActivityEvent) -> String {
        event.name.isEmpty ? app.bucketName(event.connectionID) : event.name
    }

    /// 「R2 / photos/2025」：存储桶名加所在文件夹
    private func location(of event: ActivityEvent) -> String {
        let bucket = app.bucketName(event.connectionID)
        let parent = event.parentKey
        return parent.isEmpty ? bucket : "\(bucket) / \(parent.dropLast())"
    }

    /// 展开后列出的明细：文件夹行不含文件夹本身
    private var detailEvents: [ActivityEvent] {
        row.kind == .folder ? row.events.filter { $0.id != row.primary.id } : row.events
    }

    // MARK: 操作

    @ViewBuilder
    private var trailing: some View {
        if row.kind != .single {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 26)
        } else if row.primary.status.isRunning {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26)
        } else if isHovered && canRevealInFinder(row.primary) {
            PanelIconButton(systemImage: "magnifyingglass", help: "在 Finder 中显示") {
                revealInFinder(row.primary)
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        let event = row.primary
        if row.kind != .single {
            Button(isExpanded ? "收起" : "展开") { toggle() }
            Divider()
        }
        Button("在 Finder 中显示") { revealInFinder(event) }
            .disabled(!canRevealInFinder(event))
        Button(isGone(event) ? "在 Cooper 中打开所在文件夹" : "在 Cooper 中显示") { showInCooper(event) }
        if !event.isFolder && !isGone(event) {
            Button("拷贝分享链接（1 天）") { copyShareLink(event) }
        }
        Button("拷贝路径") { copy(event.key) }
            .disabled(event.key.isEmpty)
    }

    private func primaryAction() {
        if row.kind == .single {
            if canRevealInFinder(row.primary) { revealInFinder(row.primary) }
        } else {
            toggle()
        }
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
    }

    /// 已经删除成功的条目
    private func isGone(_ event: ActivityEvent) -> Bool {
        event.action == .delete && event.status == .done
    }

    private func canRevealInFinder(_ event: ActivityEvent) -> Bool {
        app.connections.isMounted && !isGone(event)
    }

    private func revealInFinder(_ event: ActivityEvent) {
        Task {
            try? await MountManager.reveal(connectionID: event.connectionID, itemID: event.source == .finder ? event.itemID : nil, key: event.key)
        }
    }

    private func showInCooper(_ event: ActivityEvent) {
        openWindow.showMainWindow()
        app.reveal(connectionID: event.connectionID, key: event.key)
    }

    private func copyShareLink(_ event: ActivityEvent) {
        guard let connection = app.connections.connection(event.connectionID), let client = app.client(for: connection) else { return }
        copy(client.presignedURL(forKey: event.key, expiresIn: 86_400).absoluteString)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 展开后的一条明细：小图标、名称、结果
private struct ActivityDetailRow: View {
    let event: ActivityEvent
    /// 文件夹行展开时显示相对文件夹的路径
    let prefix: String?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: FileIcons.icon(name: event.name, isFolder: event.isFolder))
                .resizable()
                .frame(width: 16, height: 16)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let size = event.size, size > 0, !event.isFolder {
                Text(size.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.leading, 48)
        .padding(.trailing, 14)
        .padding(.vertical, 3)
        .background(isHovered ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard !(event.action == .delete && event.status == .done) else { return }
            Task {
                try? await MountManager.reveal(connectionID: event.connectionID, itemID: event.source == .finder ? event.itemID : nil, key: event.key)
            }
        }
        .help(event.key)
    }

    private var name: String {
        guard let prefix, event.key.hasPrefix(prefix) else { return event.name }
        let relative = String(event.key.dropFirst(prefix.count))
        return relative.hasSuffix("/") ? String(relative.dropLast()) : relative
    }
}

/// 文件图标，右下角是操作类型的小角标，颜色表示结果
private struct ActivityIcon: View {
    let event: ActivityEvent
    let isGroup: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: FileIcons.icon(name: event.name.isEmpty ? "folder" : event.name, isFolder: event.isFolder))
                .resizable()
                .frame(width: 30, height: 30)
                .opacity(event.action == .delete && event.status == .done ? 0.45 : 1)
            Circle()
                .fill(badgeColor)
                .frame(width: 15, height: 15)
                .overlay {
                    Image(systemName: badgeSymbol)
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                .offset(x: 3, y: 3)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }

    private var badgeSymbol: String {
        if event.status.needsAttention { return "exclamationmark" }
        switch event.action {
        case .upload: return "arrow.up"
        case .update: return "pencil"
        case .createFolder: return "plus"
        case .rename: return "character.cursor.ibeam"
        case .move: return "arrow.right"
        case .delete: return "trash"
        }
    }

    private var badgeColor: Color {
        switch event.status {
        case .failed, .interrupted: return Palette.warning
        case .cancelled: return .gray
        case .running, .done:
            switch event.action {
            case .upload, .update, .createFolder: return .accentColor
            case .rename, .move: return .purple
            case .delete: return .gray
            }
        }
    }
}

/// 主窗口里做的操作带一个「Cooper」小标签
private struct SourceTag: View {
    var body: some View {
        Text("Cooper")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Palette.field, in: Capsule())
            .fixedSize()
    }
}

/// 记录的文字描述
enum ActivityText {
    /// 单条记录的状态，如「上传」「正在上传…」「上传失败」「移到 R2 / docs」
    static func status(of event: ActivityEvent, location: String) -> String {
        let verb = verb(event.action, event: event, location: location)
        switch event.status {
        case .running: return "正在\(noun(event.action))…"
        case .done: return verb
        case .failed: return "\(noun(event.action))失败"
        case .cancelled: return "已取消\(noun(event.action))"
        case .interrupted: return "\(noun(event.action))未完成"
        }
    }

    /// 合并行的标题，如「上传了 5 个文件」「删除了 3 项」
    static func batchTitle(action: ActivityAction, events: [ActivityEvent]) -> String {
        let count = events.count
        let allFiles = events.allSatisfy { !$0.isFolder }
        let allFolders = events.allSatisfy(\.isFolder)
        let unit = allFiles ? "个文件" : allFolders ? "个文件夹" : "项"
        switch action {
        case .upload: return "上传了 \(count) \(unit)"
        case .update: return "修改了 \(count) 个文件"
        case .createFolder: return "新建了 \(count) 个文件夹"
        case .rename: return "重命名了 \(count) \(unit)"
        case .move: return "移动了 \(count) \(unit)"
        case .delete: return "删除了 \(count) \(unit)"
        }
    }

    private static func verb(_ action: ActivityAction, event: ActivityEvent, location: String) -> String {
        switch action {
        case .upload: event.isFolder ? "上传文件夹\(event.fileCount.map { " · \($0) 个文件" } ?? "")" : "上传"
        case .update: "修改"
        case .createFolder: "新建文件夹"
        case .rename: "重命名"
        case .move: "移到 \(location)"
        case .delete: "删除"
        }
    }

    private static func noun(_ action: ActivityAction) -> String {
        switch action {
        case .upload: "上传"
        case .update: "保存修改"
        case .createFolder: "新建文件夹"
        case .rename: "重命名"
        case .move: "移动"
        case .delete: "删除"
        }
    }
}

// MARK: - 底部

private struct PanelFooter: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            Button {
                openWindow.showMainWindow()
            } label: {
                Label("打开 Cooper", systemImage: "macwindow")
            }
            .buttonStyle(.borderless)
            Spacer()
            if app.transfers.activeCount > 0 {
                Button {
                    openWindow.showMainWindow()
                    app.selection = .transfers
                } label: {
                    Label("传输 \(app.transfers.activeCount)", systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("在主窗口里查看上传和下载")
            }
            PanelIconButton(systemImage: "gearshape", help: "设置") {
                openWindow.showMainWindow()
                app.selection = .settings
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
