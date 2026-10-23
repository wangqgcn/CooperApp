import SwiftUI
import SyncCore

/// 「移动到…」：在当前存储桶里逐级选择目标文件夹。只能在同一个存储桶内移动。
struct MoveSheet: View {
    let browser: BrowserModel
    let ids: Set<String>
    @Environment(\.dismiss) private var dismiss

    @State private var location = ""
    @State private var folders: [String] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("把 \(ids.count) 个项目移动到…")
                .font(.headline)

            HStack(spacing: 6) {
                Button {
                    location = S3Path.parent(of: location)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(location.isEmpty)
                .help("上一级")
                Label(location.isEmpty ? browser.folderName : S3Path.name(of: location), systemImage: location.isEmpty ? "externaldrive" : "folder")
                    .lineLimit(1)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            List {
                if let loadError {
                    Text(loadError)
                        .foregroundStyle(.secondary)
                } else if folders.isEmpty && !isLoading {
                    Text("这里没有子文件夹")
                        .foregroundStyle(.secondary)
                }
                ForEach(folders, id: \.self) { folder in
                    Button {
                        location = folder
                    } label: {
                        HStack {
                            Label(S3Path.name(of: folder), systemImage: "folder")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // 不能进入正在移动的文件夹
                    .disabled(ids.contains(folder))
                }
            }
            .frame(height: 260)

            HStack {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("移到这里") {
                    browser.move(ids, to: location)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canMoveHere)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { location = browser.prefix }
        .task(id: location) { await load() }
    }

    private var movingFolders: [String] {
        ids.filter { S3Path.isFolder($0) }
    }

    private var canMoveHere: Bool {
        location != browser.prefix && !movingFolders.contains { location.hasPrefix($0) }
    }

    private var hint: String {
        if location == browser.prefix { return "项目已经在这个文件夹里" }
        if !canMoveHere { return "不能移到正在移动的文件夹里面" }
        return ""
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            folders = try await browser.client.listFolder(prefix: location).folderPrefixes
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            loadError = nil
        } catch {
            folders = []
            loadError = "读取文件夹失败：\(error.localizedDescription)"
        }
    }
}
