import Foundation
import Observation
import S3Kit
import SyncCore
import UniformTypeIdentifiers

/// 文件列表里的一行。
struct BrowserItem: Identifiable, Hashable, Sendable {
    let key: String
    let name: String
    let isFolder: Bool
    let size: Int64
    let modified: Date?
    let etag: String?
    /// 文件夹或按扩展名粗分的文件类型，类型筛选用
    let itemKind: ItemKind
    /// 系统给出的种类描述，如「ZIP 归档」，和 Finder 的「种类」一栏一致。排序时会反复读取，所以只算一次
    let kind: String

    init(key: String, name: String, isFolder: Bool, size: Int64, modified: Date?, etag: String?) {
        self.key = key
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        self.etag = etag
        itemKind = isFolder ? .folder : .file(FileCategory.of(key: key))
        kind = isFolder ? "文件夹" : UTType(filenameExtension: (name as NSString).pathExtension)?.localizedDescription ?? "文稿"
    }

    var id: String { key }

    // 表格排序用的非可选值
    var sortDate: Date { modified ?? .distantPast }
    var sortSize: Int64 { isFolder ? -1 : size }
}

/// 标题区「排序」菜单里的排序依据，和点表头排序共用 sortOrder
enum BrowserSortField: CaseIterable, Identifiable {
    case name, date, size, kind

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "名称"
        case .kind: "种类"
        case .size: "大小"
        case .date: "修改时间"
        }
    }

    func comparator(_ order: SortOrder) -> KeyPathComparator<BrowserItem> {
        switch self {
        case .name: KeyPathComparator(\.name, comparator: .localizedStandard, order: order)
        case .kind: KeyPathComparator(\.kind, comparator: .localizedStandard, order: order)
        case .size: KeyPathComparator(\.sortSize, order: order)
        case .date: KeyPathComparator(\.sortDate, order: order)
        }
    }

    fileprivate var keyPath: PartialKeyPath<BrowserItem> & Sendable {
        switch self {
        case .name: \.name
        case .kind: \.kind
        case .size: \.sortSize
        case .date: \.sortDate
        }
    }
}

/// 路径栏的一段。
struct Breadcrumb: Identifiable, Hashable {
    let name: String
    let prefix: String
    var id: String { prefix }
}

/// 一个存储桶的浏览状态：当前文件夹、列表、选择、前进后退，以及新建、改名、删除等操作。
@MainActor
@Observable
final class BrowserModel {
    let connection: Connection
    /// 侧栏和路径栏里显示的存储桶名
    let folderName: String
    @ObservationIgnored let client: S3Client
    @ObservationIgnored private weak var app: AppModel?

    private(set) var prefix = ""
    private(set) var items: [BrowserItem] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    var selection = Set<String>()
    var sortOrder = [KeyPathComparator(\BrowserItem.name, comparator: .localizedStandard)]
    var searchText = ""
    /// 只显示某一类条目，nil 表示全部
    var typeFilter: ItemKind?
    /// 设置后弹出 Quick Look
    var previewURL: URL?
    /// 进行中的操作（改名、删除、准备预览），显示在列表底部
    private(set) var activity: String?
    var operationError: String?

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    /// 列表读完后要选中的条目（菜单栏「在 Cooper 中显示」）
    @ObservationIgnored private var pendingSelection: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(connection: Connection, folderName: String, client: S3Client, app: AppModel) {
        self.connection = connection
        self.folderName = folderName
        self.client = client
        self.app = app
        load()
    }

    // MARK: - 显示

    /// 当前文件夹里经过类型筛选、搜索过滤和排序的条目，文件夹始终排在前面
    var visibleItems: [BrowserItem] {
        var filtered = items
        if let typeFilter {
            filtered = filtered.filter { $0.itemKind == typeFilter }
        }
        if !searchText.isEmpty {
            filtered = filtered.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        let sorted = filtered.sorted(using: sortOrder)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    /// 标题区的统计：「2 项，208 MB」，大小只算文件
    var visibleSummary: String {
        let visible = visibleItems
        let bytes = visible.reduce(Int64(0)) { $0 + ($1.isFolder ? 0 : $1.size) }
        let count = "\(visible.count) 项"
        return visible.contains(where: { !$0.isFolder }) ? "\(count)，\(bytes.formatted(.byteCount(style: .file)))" : count
    }

    var sortField: BrowserSortField {
        get {
            let keyPath = sortOrder.first?.keyPath
            return BrowserSortField.allCases.first { $0.keyPath == keyPath } ?? .name
        }
        set { sortOrder = [newValue.comparator(sortDirection)] }
    }

    var sortDirection: SortOrder {
        get { sortOrder.first?.order ?? .forward }
        set { sortOrder = [sortField.comparator(newValue)] }
    }

    var selectedItems: [BrowserItem] {
        items.filter { selection.contains($0.id) }
    }

    var title: String {
        prefix.isEmpty ? folderName : S3Path.name(of: prefix)
    }

    var breadcrumbs: [Breadcrumb] {
        var crumbs = [Breadcrumb(name: folderName, prefix: "")]
        var current = ""
        for part in prefix.split(separator: "/", omittingEmptySubsequences: false).dropLast() {
            current += part + "/"
            crumbs.append(Breadcrumb(name: String(part), prefix: current))
        }
        return crumbs
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    // MARK: - 导航

    func load() {
        loadTask?.cancel()
        let (prefix, client) = (prefix, client)
        isLoading = true
        loadTask = Task {
            do {
                let listing = try await client.listFolder(prefix: prefix)
                guard !Task.isCancelled else { return }
                items = Self.items(from: listing, prefix: prefix)
                loadError = nil
                selection.formIntersection(items.map(\.id))
                if let pending = pendingSelection {
                    pendingSelection = nil
                    if items.contains(where: { $0.id == pending }) { selection = [pending] }
                }
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    func navigate(to newPrefix: String) {
        guard newPrefix != prefix else { return }
        backStack.append(prefix)
        forwardStack.removeAll()
        show(newPrefix)
    }

    /// 进入 key 所在的文件夹并选中它；key 为空时只回到存储桶根目录
    func reveal(_ key: String) {
        let folder = key.isEmpty ? "" : S3Path.parent(of: key)
        pendingSelection = key.isEmpty ? nil : key
        if folder == prefix {
            load()
        } else {
            navigate(to: folder)
        }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(prefix)
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(prefix)
        show(next)
    }

    private func show(_ newPrefix: String) {
        prefix = newPrefix
        items = []
        selection = []
        searchText = ""
        load()
    }

    /// 双击：单个文件夹就进入，文件就预览
    func open(_ ids: Set<String>) {
        let targets = items.filter { ids.contains($0.id) }
        if targets.count == 1, let item = targets.first, item.isFolder {
            navigate(to: item.key)
        } else if let file = targets.first(where: { !$0.isFolder }) {
            preview(file)
        }
    }

    // MARK: - 操作

    func preview(_ item: BrowserItem) {
        guard !item.isFolder else { return }
        let (client, connectionID) = (client, connection.id)
        perform("正在准备预览「\(item.name)」…") {
            self.previewURL = try await PreviewCache.file(for: item, connectionID: connectionID, client: client)
        }
    }

    func createFolder(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if let problem = nameProblem(name) {
            operationError = problem
            return
        }
        let key = prefix + name + "/"
        perform("正在新建文件夹…") {
            try await self.track([self.draft(.createFolder, key: key)]) {
                try await self.client.putObject(key: key, data: Data())
            }
            self.app?.bucketChanged(self.connection.id)
        }
    }

    func rename(_ item: BrowserItem, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard name != item.name else { return }
        if let problem = nameProblem(name) {
            operationError = problem
            return
        }
        let newKey = prefix + name + (item.isFolder ? "/" : "")
        perform("正在重命名「\(item.name)」…") {
            // S3 没有改名操作：复制到新位置再删除旧的，文件夹会处理里面的每个对象
            try await self.track([self.draft(.rename, key: newKey, previousKey: item.key, size: item.isFolder ? nil : item.size)]) {
                if item.isFolder {
                    try await self.client.moveFolder(from: item.key, to: newKey)
                } else {
                    try await self.client.moveObject(from: item.key, to: newKey, size: item.size)
                }
            }
            self.app?.bucketChanged(self.connection.id)
        }
    }

    func delete(_ ids: Set<String>) {
        let targets = items.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        perform("正在删除 \(targets.count) 个项目…") {
            let files = targets.filter { !$0.isFolder }
            if !files.isEmpty {
                try await self.track(files.map { self.draft(.delete, key: $0.key, size: $0.size) }) {
                    try await self.client.deleteObjects(keys: files.map(\.key))
                }
            }
            for folder in targets where folder.isFolder {
                try await self.track([self.draft(.delete, key: folder.key)]) {
                    try await self.client.deleteFolder(prefix: folder.key)
                }
            }
            self.selection.subtract(ids)
            self.app?.bucketChanged(self.connection.id)
        }
    }

    /// 把条目移到同一存储桶里的另一个文件夹。目标位置有同名项目时整个操作不执行。
    func move(_ ids: Set<String>, to destination: String) {
        let targets = items.filter { ids.contains($0.id) }
        guard !targets.isEmpty, destination != prefix else { return }
        if let folder = targets.first(where: { $0.isFolder && destination.hasPrefix($0.key) }) {
            operationError = "不能把「\(folder.name)」移到它自己里面"
            return
        }
        perform("正在移动 \(targets.count) 个项目…") {
            let existing = try await self.client.listFolder(prefix: destination)
            let taken = Set(existing.folderPrefixes + existing.objects.map(\.key))
            let conflicts = targets.filter { taken.contains(destination + $0.name + ($0.isFolder ? "/" : "")) }
            guard conflicts.isEmpty else {
                throw BrowserError(message: "目标文件夹里已经有同名项目：\(conflicts.map(\.name).joined(separator: "、"))")
            }
            for item in targets {
                let newKey = destination + item.name + (item.isFolder ? "/" : "")
                try await self.track([self.draft(.move, key: newKey, previousKey: item.key, size: item.isFolder ? nil : item.size)]) {
                    if item.isFolder {
                        try await self.client.moveFolder(from: item.key, to: newKey)
                    } else {
                        try await self.client.moveObject(from: item.key, to: newKey, size: item.size)
                    }
                }
            }
            self.selection.subtract(ids)
            self.app?.bucketChanged(self.connection.id)
        }
    }

    func shareURL(for item: BrowserItem, expiresIn seconds: Int) -> URL {
        client.presignedURL(forKey: item.key, expiresIn: seconds)
    }

    /// 配置了公开域名时的公开地址
    func publicURL(for item: BrowserItem) -> URL? {
        connection.publicBaseURL.map { S3Client.publicURL(base: $0, key: item.key) }
    }

    func upload(_ urls: [URL]) {
        app?.transfers.upload(urls, to: prefix, connectionID: connection.id, folderName: folderName, client: client)
    }

    func download(_ ids: Set<String>) {
        let targets = items.filter { ids.contains($0.id) }
        app?.transfers.download(targets, folderName: folderName, client: client)
    }

    // MARK: - 工具

    private func draft(_ action: ActivityAction, key: String, previousKey: String? = nil, size: Int64? = nil) -> ActivityDraft {
        ActivityDraft(action, connectionID: connection.id, key: key, previousKey: previousKey, size: size)
    }

    /// 记进菜单栏的操作记录，错误照常抛出
    private func track(_ drafts: [ActivityDraft], _ work: () async throws -> Void) async throws {
        if let activity = app?.activity {
            try await activity.track(drafts, work)
        } else {
            try await work()
        }
    }

    private func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "名称不能为空" }
        if name.contains("/") { return "名称里不能有「/」" }
        if name == "." || name == ".." { return "名称不能是「.」或「..」" }
        if items.contains(where: { $0.name == name }) { return "这里已经有名为「\(name)」的项目" }
        return nil
    }

    private func perform(_ message: String, _ work: @escaping @MainActor () async throws -> Void) {
        activity = message
        Task {
            do {
                try await work()
            } catch where !(error is CancellationError) {
                operationError = error.localizedDescription
            } catch {}
            activity = nil
        }
    }

    nonisolated private static func items(from listing: FolderListing, prefix: String) -> [BrowserItem] {
        let folders = listing.folderPrefixes.map {
            BrowserItem(key: $0, name: S3Path.name(of: $0), isFolder: true, size: 0, modified: nil, etag: nil)
        }
        // key 等于前缀本身的是文件夹占位对象
        let files = listing.objects.filter { $0.key != prefix }.map {
            BrowserItem(key: $0.key, name: S3Path.name(of: $0.key), isFolder: false, size: $0.size, modified: $0.lastModified, etag: $0.etag)
        }
        return folders + files
    }
}

/// 操作前检查出的问题，直接显示给用户
struct BrowserError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
