import S3Kit
import SwiftUI
import SyncCore

/// 编辑中的连接表单
struct ConnectionDraft: Equatable {
    var provider = StorageProvider.r2
    var name = ""
    var endpoint = ""
    var bucket = ""
    var region = StorageProvider.r2.defaultRegion
    var usePathStyle = StorageProvider.r2.usesPathStyle
    var accessKeyId = ""
    var secretAccessKey = ""
    /// 可选的公开访问域名
    var publicBaseURL = ""

    init() {}

    init(_ connection: Connection, credentials: S3Credentials?) {
        provider = connection.storageProvider
        name = connection.name
        endpoint = connection.config.endpoint.absoluteString
        bucket = connection.config.bucket
        region = connection.config.region
        usePathStyle = connection.config.usePathStyle
        accessKeyId = credentials?.accessKeyId ?? ""
        secretAccessKey = credentials?.secretAccessKey ?? ""
        publicBaseURL = connection.publicBaseURL?.absoluteString ?? ""
    }

    /// 换服务商：还没改过的 endpoint、region 跟着换成新服务商的默认值
    mutating func switchProvider(from old: StorageProvider) {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespaces)
        let endpointUntouched = trimmedEndpoint.isEmpty || trimmedEndpoint == old.endpoint(forRegion: region)
        if region.trimmingCharacters(in: .whitespaces).isEmpty || region == old.defaultRegion {
            region = provider.defaultRegion
        }
        if endpointUntouched {
            endpoint = provider.endpoint(forRegion: region) ?? ""
        }
        usePathStyle = provider.usesPathStyle
    }

    /// 改区域：endpoint 还是按旧区域自动生成的，就按新区域重新生成
    mutating func regionChanged(from oldRegion: String) {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespaces)
        guard trimmedEndpoint.isEmpty || trimmedEndpoint == provider.endpoint(forRegion: oldRegion),
              let generated = provider.endpoint(forRegion: region) else { return }
        endpoint = generated
    }

    /// R2 控制台里复制的地址带着存储桶名（…cloudflarestorage.com/my-bucket）。存储桶还没填时拆开
    mutating func splitBucketFromEndpoint() {
        guard bucket.trimmingCharacters(in: .whitespaces).isEmpty,
              var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespaces)),
              components.host != nil else { return }
        let parts = components.path.split(separator: "/")
        guard parts.count == 1 else { return }
        bucket = String(parts[0])
        components.path = ""
        endpoint = components.string ?? endpoint
    }

    /// 允许的 endpoint：带 http(s) 和主机名的地址
    var endpointURL: URL? {
        let text = endpoint.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
        return url
    }

    var endpointError: String? {
        let text = endpoint.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, endpointURL == nil else { return nil }
        return "请填写完整的地址，以 https:// 开头"
    }

    /// 留空表示不配置；填了就必须是 http(s) 地址
    var publicURL: URL? {
        let text = publicBaseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return nil }
        return url
    }

    var publicURLError: String? {
        let text = publicBaseURL.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, publicURL == nil else { return nil }
        return "请填写完整的地址，以 https:// 开头"
    }

    /// 路径式地址开关：只有自建和其他服务商显示，或者旧连接的设置和预设不一致时也显示出来
    var showsPathStyle: Bool {
        provider.allowsPathStyleChoice || usePathStyle != provider.usesPathStyle
    }

    var config: S3Config? {
        let bucket = bucket.trimmingCharacters(in: .whitespaces)
        let region = region.trimmingCharacters(in: .whitespaces)
        guard let url = endpointURL, !bucket.isEmpty else { return nil }
        return S3Config(endpoint: url, bucket: bucket, region: region.isEmpty ? provider.defaultRegion : region, usePathStyle: usePathStyle)
    }

    var credentials: S3Credentials {
        S3Credentials(
            accessKeyId: accessKeyId.trimmingCharacters(in: .whitespaces),
            secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespaces)
        )
    }

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && config != nil
            && !credentials.accessKeyId.isEmpty && !credentials.secretAccessKey.isEmpty && publicURLError == nil
    }
}

@MainActor
@Observable
final class ConnectionsModel {
    /// 表单底部显示的状态
    enum FormStatus: Equatable {
        case idle
        case working(String)
        case success(String)
        case failure(String)
    }

    private(set) var connections: [Connection] = []
    /// 钥匙串里找不到密钥的连接
    private(set) var missingCredentials: Set<String> = []
    /// 正在编辑的连接；nil 表示新建
    private(set) var editingID: String?
    /// 复制连接时源连接的名称，面板标题和说明用
    private(set) var duplicateSourceName: String?
    var draft = ConnectionDraft()
    private(set) var formStatus = FormStatus.idle
    /// 挂载相关操作的结果，显示在设置页
    var status = ""
    var isBusy = false
    var isMounted = false
    /// 某个连接被保存或移除后调用，参数是连接 id
    @ObservationIgnored var onChange: ((String) -> Void)?
    /// 卸载 CooperDrive 后调用
    @ObservationIgnored var onUnmount: (() -> Void)?

    init() {
        do {
            connections = try ConnectionStore.loadAll()
        } catch {
            status = "读取连接失败：\(error.localizedDescription)"
        }
        reloadCredentialState()
    }

    var isNew: Bool { editingID == nil }

    var isFormWorking: Bool {
        if case .working = formStatus { return true }
        return false
    }

    /// 各存储桶在 CooperDrive 里的文件夹名，和扩展的算法一致
    var folderNames: [String: String] {
        DriveNaming.folderNames(connections.map { ($0.id, $0.name) })
    }

    func connection(_ id: String) -> Connection? {
        connections.first { $0.id == id }
    }

    /// 打开表单前准备草稿；id 为 nil 表示新建
    func beginEditing(_ id: String?) {
        editingID = id
        duplicateSourceName = nil
        formStatus = .idle
        if let id, let connection = connection(id) {
            draft = ConnectionDraft(connection, credentials: (try? CredentialStore.load(for: id)) ?? nil)
        } else {
            draft = ConnectionDraft()
        }
    }

    /// 以已有连接为模板新建：服务商、Endpoint、区域、密钥和公开域名都带过来，名称加「副本」
    func beginDuplicating(_ id: String) {
        guard let source = connection(id) else { return beginEditing(nil) }
        editingID = nil
        duplicateSourceName = folderNames[id] ?? source.name
        formStatus = .idle
        draft = ConnectionDraft(source, credentials: (try? CredentialStore.load(for: id)) ?? nil)
        draft.name = copyName(for: source.name)
    }

    /// 「R2 副本」，已被占用时依次试「R2 副本 2」「R2 副本 3」…
    private func copyName(for name: String) -> String {
        let taken = Set(connections.map { $0.name.lowercased() })
        let base = "\(name) 副本"
        var candidate = base
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    /// 和草稿指向同一个存储桶（Endpoint 主机和桶名都相同）的其他连接
    var sameBucketConnection: Connection? {
        guard let config = draft.config else { return nil }
        return connections.first {
            $0.id != editingID
                && $0.config.endpoint.host()?.lowercased() == config.endpoint.host()?.lowercased()
                && $0.config.bucket == config.bucket
        }
    }

    /// 启动时把旧版本的单桶挂载换成 CooperDrive
    func prepare() async {
        do {
            let removed = try await MountManager.removeLegacyDomains()
            if removed > 0, !connections.isEmpty {
                try await MountManager.mount()
                status = "已升级为 CooperDrive 挂载，每个存储桶是其中一个文件夹"
            }
        } catch {
            status = "失败：升级旧挂载时出错：\(error.localizedDescription)"
        }
        isMounted = await MountManager.isMounted()
    }

    /// 保存表单，成功时返回连接 id。配置和密钥写好后再挂载，挂载出错不影响保存结果
    func save() async -> String? {
        guard let config = draft.config else { return nil }
        let id = editingID ?? UUID().uuidString
        let connection = Connection(
            id: id,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            config: config,
            publicBaseURL: draft.publicURL,
            provider: draft.provider.rawValue
        )
        formStatus = .working("正在保存…")
        do {
            // 先存密钥再写配置：扩展发现配置文件变了才重新加载，那时密钥必须已经就位
            try CredentialStore.save(draft.credentials, for: id)
            var list = connections
            if let index = list.firstIndex(where: { $0.id == id }) {
                list[index] = connection
            } else {
                list.append(connection)
            }
            try ConnectionStore.saveAll(list)
            connections = list
            missingCredentials.remove(id)
        } catch {
            formStatus = .failure("保存失败：\(error.localizedDescription)")
            return nil
        }
        formStatus = .idle
        editingID = id
        onChange?(id)

        // 面板先关掉，挂载在后台进行，结果显示在设置页
        Task {
            await run("正在挂载…") {
                try await MountManager.mount()
                self.isMounted = true
                try? await MountManager.signalChanges()
                let folder = self.folderNames[id] ?? connection.name
                return "已保存，在 Finder 侧栏「\(CooperDrive.sidebarName)」里可以看到「\(folder)」"
            }
        }
        return id
    }

    func delete(id: String) async {
        await run("正在移除…") {
            var list = self.connections
            list.removeAll { $0.id == id }
            try ConnectionStore.saveAll(list)
            CredentialStore.delete(for: id)
            SyncStateLocation.remove(forConnection: id)
            self.connections = list
            self.missingCredentials.remove(id)
            self.onChange?(id)
            if self.isMounted {
                try? await MountManager.signalChanges()
            }
            return "已移除连接，存储桶里的数据不受影响"
        }
    }

    func testConnection() async {
        guard let config = draft.config else { return }
        let credentials = draft.credentials
        formStatus = .working("正在测试连接…")
        do {
            let page = try await S3Client(config: config, credentials: credentials).listObjects(prefix: "", maxKeys: 5)
            let total = page.commonPrefixes.count + page.objects.count
            formStatus = .success(total == 0 ? "连接成功，存储桶是空的" : "连接成功，可以读取存储桶里的内容")
        } catch {
            formStatus = .failure(error.localizedDescription)
        }
    }

    /// 表单内容改了以后，上一次的测试结果不再有意义
    func draftChanged() {
        if case .working = formStatus { return }
        formStatus = .idle
    }

    func mount() async {
        await run("正在挂载…") {
            try await MountManager.mount()
            self.isMounted = true
            return "已挂载，在 Finder 侧栏「位置」里可以看到「\(CooperDrive.sidebarName)」"
        }
    }

    func unmount() async {
        await run("正在卸载…") {
            try await MountManager.unmount()
            self.isMounted = false
            self.onUnmount?()
            return "已卸载，本机缓存的文件已移除"
        }
    }

    func openInFinder(connectionID: String? = nil) async {
        await run(nil) {
            try await MountManager.openInFinder(connectionID: connectionID)
            return nil
        }
    }

    func refresh() async {
        await run("正在刷新…") {
            try await MountManager.refresh(connectionIDs: self.connections.map(\.id))
            return "已请求检查所有存储桶的远端变化，几秒后 Finder 里会更新"
        }
    }

    /// 主程序开着时每分钟通知一次。扩展被系统结束后，靠这个把它唤醒继续发现远端变化。
    func keepPolling() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard isMounted else { continue }
            try? await MountManager.signalChanges()
        }
    }

    private func reloadCredentialState() {
        missingCredentials = Set(connections.map(\.id).filter { ((try? CredentialStore.load(for: $0)) ?? nil) == nil })
    }

    private func run(_ message: String?, _ work: () async throws -> String?) async {
        isBusy = true
        if let message { status = message }
        do {
            if let result = try await work() { status = result }
        } catch {
            status = "失败：\(error.localizedDescription)"
        }
        isBusy = false
    }
}

/// 添加或编辑存储桶的面板，从主窗口顶部滑出。
struct ConnectionEditorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingDelete = false

    var body: some View {
        @Bindable var model = app.connections
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title(model))
                    .font(.system(size: 22, weight: .semibold))
                Text(subtitle(model))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 16)

            ScrollView {
                fields(model)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 4)
                    .disabled(model.isFormWorking)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 320, idealHeight: 540)

            footer(model)
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 22)
        }
        .frame(width: 540)
        .background(Palette.page)
        .onChange(of: model.draft) { model.draftChanged() }
        .onChange(of: model.draft.provider) { old, _ in model.draft.switchProvider(from: old) }
        .onChange(of: model.draft.region) { old, _ in model.draft.regionChanged(from: old) }
        .onChange(of: model.draft.endpoint) { old, new in
            // 一次多了好几个字符，多半是粘贴进来的完整地址
            if new.count - old.count > 1 { model.draft.splitBucketFromEndpoint() }
        }
        .confirmationDialog("移除这个存储桶连接？", isPresented: $isConfirmingDelete) {
            Button("移除", role: .destructive) {
                guard let id = model.editingID else { return }
                dismiss()
                Task { await model.delete(id: id) }
            }
        } message: {
            Text("CooperDrive 里对应的文件夹和本机缓存会被移除，存储桶里的数据不受影响。")
        }
    }

    private func title(_ model: ConnectionsModel) -> String {
        if !model.isNew { return "编辑连接" }
        return model.duplicateSourceName == nil ? "添加连接" : "复制连接"
    }

    private func subtitle(_ model: ConnectionsModel) -> String {
        if model.isNew, let source = model.duplicateSourceName {
            return "已填好「\(source)」的服务商、Endpoint 和访问密钥，改一下存储桶名就可以保存。"
        }
        return "填写存储桶的 S3 访问信息。建议使用只授权给这一个存储桶的访问密钥。"
    }

    @ViewBuilder
    private func fields(_ model: ConnectionsModel) -> some View {
        @Bindable var model = model
        let draft = model.draft
        let provider = draft.provider
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    FieldLabel(title: "服务商")
                    if let url = provider.tutorialURL {
                        Button {
                            openURL(url)
                        } label: {
                            HStack(spacing: 4) {
                                Text("连接教程")
                                Image(systemName: "arrow.up.right.square")
                            }
                        }
                        .buttonStyle(.link)
                        .help("在浏览器中查看如何创建访问密钥")
                    }
                }
                ProviderPicker(selection: $model.draft.provider)
            }

            LabeledField(title: "连接名称", required: true, hint: "在 Finder 中显示为文件夹名") {
                FilledField(placeholder: provider.namePlaceholder, text: $model.draft.name)
            }

            LabeledField(title: "S3 API Endpoint", required: true, hint: provider.endpointHint, error: draft.endpointError) {
                FilledField(placeholder: provider.endpointPlaceholder, text: $model.draft.endpoint, isInvalid: draft.endpointError != nil)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 16) {
                    LabeledField(title: "存储桶", required: true) {
                        FilledField(placeholder: provider.bucketPlaceholder, text: $model.draft.bucket)
                    }
                    LabeledField(title: "区域", hint: provider.regionHint) {
                        FilledField(placeholder: provider.defaultRegion, text: $model.draft.region)
                    }
                }
                if let existing = model.sameBucketConnection {
                    // 只提示不拦截：同一个桶挂两次也能用，只是 Finder 里会出现两个相同的文件夹
                    Label("已有连接「\(model.folderNames[existing.id] ?? existing.name)」指向这个存储桶，保存后 Finder 里会出现两个相同的文件夹。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if draft.showsPathStyle {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("使用路径式地址", isOn: $model.draft.usePathStyle)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text("开启时请求地址为 endpoint/存储桶/文件，MinIO 和大多数自建服务需要开启。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledField(title: "Access Key ID", required: true) {
                FilledField(placeholder: "", text: $model.draft.accessKeyId)
            }

            LabeledField(title: "Secret Access Key", required: true, hint: "存储在系统钥匙串中") {
                FilledField(placeholder: "", text: $model.draft.secretAccessKey, isSecure: true)
            }

            LabeledField(title: "公开域名 / 自定义域名", hint: "可选，用于直接链接", error: draft.publicURLError) {
                FilledField(placeholder: provider.publicURLPlaceholder, text: $model.draft.publicBaseURL, isInvalid: draft.publicURLError != nil)
            }
        }
    }

    @ViewBuilder
    private func footer(_ model: ConnectionsModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            FormStatusView(status: model.formStatus)
            HStack(spacing: 10) {
                Button {
                    Task { await model.testConnection() }
                } label: {
                    Label("测试连接", systemImage: "bolt.horizontal")
                }
                .controlSize(.large)
                .disabled(!model.draft.isComplete || model.isFormWorking)
                if !model.isNew {
                    Button("移除…", role: .destructive) { isConfirmingDelete = true }
                        .controlSize(.large)
                        .disabled(model.isFormWorking)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button(model.isNew ? "添加连接" : "保存") {
                    Task {
                        let isNew = model.isNew
                        if let id = await model.save() {
                            app.finishEditing(savedID: id, isNew: isNew)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.draft.isComplete || model.isFormWorking)
            }
        }
    }
}

/// 服务商选择：点开是带图标和勾选标记的列表
private struct ProviderPicker: View {
    @Binding var selection: StorageProvider
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 10) {
                ProviderBadge(provider: selection, size: 22)
                Text(selection.displayName)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(StorageProvider.allCases) { provider in
                    ProviderOption(provider: provider, isSelected: provider == selection) {
                        selection = provider
                        isOpen = false
                    }
                }
            }
            .padding(6)
            .frame(width: 280)
        }
        .accessibilityLabel("服务商：\(selection.displayName)")
    }
}

private struct ProviderOption: View {
    let provider: StorageProvider
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ProviderBadge(provider: provider, size: 20)
                Text(provider.displayName)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isHovered ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// 测试或保存的结果
private struct FormStatusView: View {
    let status: ConnectionsModel.FormStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working(let message):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .foregroundStyle(.secondary)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.success)
        case .failure(let message):
            Label {
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
        }
    }
}
