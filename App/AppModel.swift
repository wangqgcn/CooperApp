import Foundation
import Observation
import S3Kit
import SyncCore

/// 侧栏里的一项，也是主窗口右边显示的页面
enum SidebarItem: Hashable {
    case home
    case bucket(String)
    case storage
    case transfers
    case settings
}

/// 正在添加、编辑或复制的连接，用来弹出表单面板
enum ConnectionEditor: Identifiable, Hashable {
    case new
    case edit(String)
    /// 以某个连接为模板新建
    case duplicate(String)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let id): id
        case .duplicate(let id): "duplicate-\(id)"
        }
    }
}

/// 整个 App 共用的状态：存储桶连接、传输任务，以及各存储桶的浏览状态。
@MainActor
@Observable
final class AppModel {
    let connections = ConnectionsModel()
    let transfers = TransferManager()
    let storage = StorageModel()
    /// 菜单栏面板的操作记录
    let activity = ActivityModel()
    /// 主窗口当前的页面。每次启动都从首页开始
    var selection: SidebarItem? = .home
    /// 不为 nil 时弹出添加或编辑存储桶的面板
    var editor: ConnectionEditor?
    /// 等待确认移除的连接
    var removalCandidate: Connection?
    /// 存储占用页显示的存储桶，nil 时显示第一个
    var dashboardBucketID: String?
    /// 每个存储桶的变化计数。上传完成、改名、删除后加一，浏览界面据此重新读取当前文件夹
    private(set) var revisions: [String: Int] = [:]
    /// 作为登录项启动：不打开主窗口，只留在菜单栏
    @ObservationIgnored var launchedAtLogin = false
    /// 切换侧栏时保留每个存储桶的浏览位置
    @ObservationIgnored private var browsers: [String: BrowserModel] = [:]
    @ObservationIgnored private var hasStarted = false

    init() {
        connections.onChange = { [weak self] connectionID in
            // 连接或密钥变了，下次访问时用新配置重建
            self?.browsers[connectionID] = nil
            self?.bucketChanged(connectionID)
        }
        connections.onUnmount = { [weak self] in
            // 卸载后记录里的条目都不在 Finder 里了
            self?.activity.clear()
        }
        transfers.onUploadFinished = { [weak self] connectionID in
            self?.bucketChanged(connectionID)
        }
        transfers.activity = activity.recorder
    }

    /// App 启动时调用一次。挂载状态、给扩展的定时提醒和操作记录都不依赖主窗口，关掉窗口后照常运行
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        activity.start()
        Task { await connections.prepare() }
        Task { await connections.keepPolling() }
    }

    // MARK: - 导航

    func open(_ connectionID: String) {
        selection = .bucket(connectionID)
    }

    /// 打开存储桶，进入 key 所在的文件夹并选中它
    func reveal(connectionID: String, key: String) {
        guard let connection = connections.connection(connectionID) else { return }
        open(connectionID)
        browser(for: connection)?.reveal(key)
    }

    func showStorage(of connectionID: String) {
        dashboardBucketID = connectionID
        selection = .storage
    }

    func addConnection() {
        connections.beginEditing(nil)
        editor = .new
    }

    func editConnection(_ connectionID: String) {
        connections.beginEditing(connectionID)
        editor = .edit(connectionID)
    }

    func duplicateConnection(_ connectionID: String) {
        connections.beginDuplicating(connectionID)
        editor = .duplicate(connectionID)
    }

    /// 表单保存成功后关闭面板；新添加的存储桶直接打开
    func finishEditing(savedID: String, isNew: Bool) {
        editor = nil
        if isNew { open(savedID) }
    }

    /// 选中的存储桶被移除后回到首页
    func fixSelection() {
        if case .bucket(let id) = selection, !connections.connections.contains(where: { $0.id == id }) {
            selection = .home
        }
        if let id = dashboardBucketID, !connections.connections.contains(where: { $0.id == id }) {
            dashboardBucketID = nil
        }
    }

    // MARK: - 存储桶

    /// 存储桶的浏览状态。钥匙串里没有密钥时返回 nil。
    func browser(for connection: Connection) -> BrowserModel? {
        let folderName = connections.folderNames[connection.id] ?? connection.name
        if let browser = browsers[connection.id], browser.connection == connection, browser.folderName == folderName {
            return browser
        }
        guard let client = client(for: connection) else { return nil }
        let browser = BrowserModel(connection: connection, folderName: folderName, client: client, app: self)
        browsers[connection.id] = browser
        return browser
    }

    /// 用钥匙串里的密钥建一个客户端，没有密钥时返回 nil。
    func client(for connection: Connection) -> S3Client? {
        if let browser = browsers[connection.id], browser.connection == connection { return browser.client }
        guard let credentials = (try? CredentialStore.load(for: connection.id)) ?? nil else { return nil }
        return S3Client(config: connection.config, credentials: credentials)
    }

    func startScan(_ connection: Connection) {
        guard let client = client(for: connection) else { return }
        storage.scan(connection.id, client: client)
    }

    /// 存储桶内容在 App 里被改动过：刷新浏览界面，并让 Finder 挂载尽快检查这个存储桶。
    func bucketChanged(_ connectionID: String) {
        revisions[connectionID, default: 0] += 1
        guard connections.isMounted else { return }
        Task {
            try? await MountManager.refresh(connectionIDs: [connectionID])
        }
    }
}
