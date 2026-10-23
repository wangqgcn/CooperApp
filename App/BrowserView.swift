import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

enum BrowserViewMode: String {
    case list, grid
}

/// 「移动到…」面板要移动的条目
private struct MoveRequest: Identifiable {
    let id = UUID()
    let ids: Set<String>
}

/// 一个存储桶的文件列表：上面是路径、统计和筛选，下面可以切换列表和图标两种视图。
struct BrowserView: View {
    @Bindable var browser: BrowserModel
    @Environment(AppModel.self) private var app
    @AppStorage("browserViewMode") private var viewMode = BrowserViewMode.list

    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: BrowserItem?
    @State private var renameText = ""
    @State private var pendingDeletion: Set<String> = []
    @State private var isConfirmingDelete = false
    @State private var isImporting = false
    @State private var shareTarget: BrowserItem?
    @State private var moveRequest: MoveRequest?
    @State private var isDropTargeted = false
    @FocusState private var isFilterFocused: Bool
    /// 图标视图里 Shift 点选的起点
    @State private var selectionAnchor: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            files
        }
        .background(Palette.page)
        .navigationTitle(browser.title)
        .toolbar { toolbar }
        .quickLookPreview($browser.previewURL)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                browser.upload(urls)
            }
        }
        .alert("新建文件夹", isPresented: $isCreatingFolder) {
            TextField("名称", text: $newFolderName)
            Button("创建") { browser.createFolder(named: newFolderName) }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名", isPresented: isRenaming, presenting: renameTarget) { item in
            TextField("名称", text: $renameText)
            Button("重命名") { browser.rename(item, to: renameText) }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: $isConfirmingDelete) {
            Button("删除", role: .destructive) { browser.delete(pendingDeletion) }
        } message: {
            Text("存储桶里的对象会被直接删除，无法恢复。")
        }
        .alert("操作失败", isPresented: hasOperationError) {
            Button("好") {}
        } message: {
            Text(browser.operationError ?? "")
        }
        .sheet(item: $shareTarget) { item in
            ShareSheet(item: item, browser: browser)
        }
        .sheet(item: $moveRequest) { request in
            MoveSheet(browser: browser, ids: request.ids)
        }
        .onChange(of: app.revisions[browser.connection.id]) {
            browser.load()
        }
    }

    // MARK: - 标题区

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            BreadcrumbBar(browser: browser)
            HStack(spacing: 8) {
                if browser.selection.isEmpty {
                    Text(browser.visibleSummary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                } else {
                    selectionBar
                }
                Spacer(minLength: 12)
                typePicker
                sortMenu
                FilledField(placeholder: "筛选…", text: $browser.searchText, icon: "magnifyingglass", height: 28, isClearable: true, focus: $isFilterFocused)
                    .frame(minWidth: 110, idealWidth: 190, maxWidth: 220)
                Picker("显示方式", selection: $viewMode) {
                    Image(systemName: "list.bullet").tag(BrowserViewMode.list)
                        .help("列表")
                    Image(systemName: "square.grid.2x2").tag(BrowserViewMode.grid)
                        .help("图标")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("切换列表或图标显示")
                Button {
                    browser.load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background {
            // ⌘F 跳到筛选框
            Button("筛选") { isFilterFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private var typePicker: some View {
        Picker("类型", selection: $browser.typeFilter) {
            Text("全部类型").tag(ItemKind?.none)
            Divider()
            ForEach(ItemKind.allKinds, id: \.self) { kind in
                Label(kind.title, systemImage: kind.systemImage).tag(Optional(kind))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("按类型筛选")
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序依据", selection: $browser.sortField) {
                ForEach(BrowserSortField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }
            .pickerStyle(.inline)
            Picker("顺序", selection: $browser.sortDirection) {
                Text("升序").tag(SortOrder.forward)
                Text("降序").tag(SortOrder.reverse)
            }
            .pickerStyle(.inline)
        } label: {
            Text("\(browser.sortField.title) \(browser.sortDirection == .forward ? "↑" : "↓")")
        }
        .fixedSize()
        .help("排序")
    }

    /// 选中条目后代替统计显示的操作
    private var selectionBar: some View {
        HStack(spacing: 2) {
            Text("已选 \(browser.selection.count) 项")
                .fontWeight(.medium)
                .padding(.trailing, 6)
                .lineLimit(1)
            Button { browser.download(browser.selection) } label: {
                Image(systemName: "arrow.down.circle")
            }
            .help("下载到「下载」文件夹")
            Button { moveRequest = MoveRequest(ids: browser.selection) } label: {
                Image(systemName: "folder")
            }
            .help("移动到其他文件夹")
            Button { shareTarget = singleSelectedFile } label: {
                Image(systemName: "link")
            }
            .disabled(singleSelectedFile == nil)
            .help("拷贝分享链接")
            Button { requestDelete(browser.selection) } label: {
                Image(systemName: "trash")
            }
            .help("删除")
            Button { browser.selection = [] } label: {
                Image(systemName: "xmark")
            }
            .help("取消选择")
        }
        .buttonStyle(.accessoryBar)
    }

    // MARK: - 文件区

    private var files: some View {
        Group {
            switch viewMode {
            case .list: table
            case .grid: grid
            }
        }
        .onKeyPress(.space) {
            guard let file = singleSelectedFile else { return .ignored }
            browser.preview(file)
            return .handled
        }
        .onDeleteCommand {
            requestDelete(browser.selection)
        }
        .dropDestination(for: URL.self) { urls, _ in
            browser.upload(urls)
            return !urls.isEmpty
        } isTargeted: {
            isDropTargeted = $0
        }
        .overlay {
            placeholder
        }
        .overlay(alignment: .bottom) {
            if let activity = browser.activity {
                ActivityBanner(text: activity)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private var table: some View {
        // 和 Finder 的列表视图一致：名称、修改日期、大小、种类，小图标、紧凑行高、斑马纹
        Table(browser.visibleItems, selection: $browser.selection, sortOrder: $browser.sortOrder) {
            TableColumn("名称", value: \.name) { item in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.icon(for: item))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(item.name)
            }
            .width(min: 200, ideal: 340)
            TableColumn("修改日期", value: \.sortDate) { item in
                Text(item.modified?.friendlyDescription ?? "--")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(item.modified?.formatted(date: .long, time: .shortened) ?? "")
            }
            .width(min: 90, ideal: 150)
            TableColumn("大小", value: \.sortSize) { item in
                Text(item.isFolder ? "--" : item.size.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 80)
            TableColumn("种类", value: \.kind) { item in
                Text(item.kind)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            browser.open(ids)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 12)], spacing: 16) {
                ForEach(browser.visibleItems) { item in
                    GridCell(item: item, isSelected: browser.selection.contains(item.id), browser: browser)
                        .onTapGesture { tap(item) }
                        .contextMenu { contextMenu(for: contextIDs(for: item)) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture { browser.selection = [] }
        .contextMenu { contextMenu(for: []) }
        .focusable()
        .focusEffectDisabled()
    }

    /// 图标视图的点选：双击打开，⌘ 加减选，Shift 连选，否则单选
    private func tap(_ item: BrowserItem) {
        let event = NSApp.currentEvent
        if event?.clickCount == 2 {
            browser.open([item.id])
            return
        }
        let flags = event?.modifierFlags ?? []
        let visible = browser.visibleItems
        if flags.contains(.shift), let anchor = selectionAnchor,
           let from = visible.firstIndex(where: { $0.id == anchor }), let to = visible.firstIndex(where: { $0.id == item.id }) {
            browser.selection = Set(visible[min(from, to)...max(from, to)].map(\.id))
            return
        }
        if flags.contains(.command) {
            browser.selection.formSymmetricDifference([item.id])
        } else {
            browser.selection = [item.id]
        }
        selectionAnchor = item.id
    }

    /// 右键点在已选中的条目上时作用于整个选择，否则只作用于这一项
    private func contextIDs(for item: BrowserItem) -> Set<String> {
        browser.selection.contains(item.id) ? browser.selection : [item.id]
    }

    @ViewBuilder
    private var placeholder: some View {
        if browser.items.isEmpty && !browser.isLoading {
            if let error = browser.loadError {
                ContentUnavailableView {
                    Label("无法读取这个文件夹", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { browser.load() }
                }
            } else {
                ContentUnavailableView {
                    Label("文件夹是空的", systemImage: "tray")
                } description: {
                    Text("把文件拖到这里即可上传")
                } actions: {
                    Button("上传文件…") { isImporting = true }
                }
            }
        } else if browser.visibleItems.isEmpty && !browser.items.isEmpty {
            if !browser.searchText.isEmpty {
                ContentUnavailableView.search(text: browser.searchText)
            } else if let typeFilter = browser.typeFilter {
                ContentUnavailableView {
                    Label("没有\(typeFilter.title)", systemImage: typeFilter.systemImage)
                } description: {
                    Text("当前文件夹里没有这个类型的项目")
                } actions: {
                    Button("显示全部类型") { browser.typeFilter = nil }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let targets = browser.items.filter { ids.contains($0.id) }
        if targets.isEmpty {
            Button("新建文件夹…") { startNewFolder() }
            Button("上传…") { isImporting = true }
        } else {
            if targets.count == 1, let item = targets.first {
                Button(item.isFolder ? "打开" : "快速查看") { browser.open(ids) }
                if !item.isFolder {
                    Button("拷贝分享链接…") { shareTarget = item }
                }
                Button("重命名…") { startRename(item) }
                Divider()
            }
            Button("下载") { browser.download(ids) }
            Button("移动到…") { moveRequest = MoveRequest(ids: ids) }
            Divider()
            Button("删除…", role: .destructive) { requestDelete(ids) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { browser.goBack() } label: {
                Label("后退", systemImage: "chevron.left")
            }
            .disabled(!browser.canGoBack)
            .help("后退")
            Button { browser.goForward() } label: {
                Label("前进", systemImage: "chevron.right")
            }
            .disabled(!browser.canGoForward)
            .help("前进")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { startNewFolder() } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
                    .labelStyle(.titleAndIcon)
            }
            .help("新建文件夹")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { isImporting = true } label: {
                Label("上传", systemImage: "arrow.up.doc")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .help("上传文件或文件夹，也可以直接拖进列表")
        }
    }

    // MARK: - 操作

    private var singleSelectedFile: BrowserItem? {
        let selected = browser.selectedItems
        guard selected.count == 1, let item = selected.first, !item.isFolder else { return nil }
        return item
    }

    private var deleteTitle: String {
        if pendingDeletion.count == 1, let item = browser.items.first(where: { pendingDeletion.contains($0.id) }) {
            return item.isFolder ? "删除文件夹「\(item.name)」及其中的所有内容？" : "删除「\(item.name)」？"
        }
        return "删除这 \(pendingDeletion.count) 个项目？"
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var hasOperationError: Binding<Bool> {
        Binding(get: { browser.operationError != nil }, set: { if !$0 { browser.operationError = nil } })
    }

    private func startNewFolder() {
        newFolderName = "未命名文件夹"
        isCreatingFolder = true
    }

    private func startRename(_ item: BrowserItem) {
        renameText = item.name
        renameTarget = item
    }

    private func requestDelete(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        pendingDeletion = ids
        isConfirmingDelete = true
    }
}

/// 图标视图里的一格：缩略图或系统图标，下面是名称。选中时和 Finder 一样给图标加灰色底、名称加强调色底
private struct GridCell: View {
    let item: BrowserItem
    let isSelected: Bool
    let browser: BrowserModel
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: thumbnail ?? FileIcons.icon(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .padding(6)
                .background(isSelected ? Color.secondary.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(width: 112)
        .contentShape(Rectangle())
        .help(item.name)
        .task(id: item.etag ?? item.key) {
            thumbnail = await ThumbnailLoader.shared.thumbnail(for: item, connectionID: browser.connection.id, client: browser.client)
        }
    }
}

/// 标题区第一行：可以点击的路径
private struct BreadcrumbBar: View {
    let browser: BrowserModel

    var body: some View {
        let crumbs = browser.breadcrumbs
        HStack(spacing: 4) {
            ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                let isLast = index == crumbs.count - 1
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    browser.navigate(to: crumb.prefix)
                } label: {
                    HStack(spacing: 5) {
                        if index == 0 {
                            ProviderBadge(provider: browser.connection.storageProvider, size: 16)
                        }
                        Text(crumb.name)
                            .fontWeight(isLast ? .semibold : .regular)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isLast ? .primary : .secondary)
                .disabled(isLast)
            }
            if browser.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 0)
        }
        .font(.title3)
        .lineLimit(1)
    }
}

private struct ActivityBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.bottom, 12)
    }
}

/// 按文件类型取系统图标，同一类型只取一次
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: BrowserItem) -> NSImage {
        icon(name: item.name, isFolder: item.isFolder)
    }

    static func icon(name: String, isFolder: Bool) -> NSImage {
        let type = isFolder ? UTType.folder : (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
        if let cached = cache[type.identifier] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache[type.identifier] = image
        return image
    }
}
