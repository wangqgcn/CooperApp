import AppKit
import Charts
import S3Kit
import SwiftUI
import SyncCore

/// 存储占用：总量、按顶层文件夹和文件类型的分布、最大的文件。
struct DashboardView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let connections = app.connections.connections
        let connection = connections.first { $0.id == app.dashboardBucketID } ?? connections.first
        Group {
            if let connection {
                content(for: connection, showsPicker: connections.count > 1)
            } else {
                ContentUnavailableView("还没有存储桶", systemImage: "chart.bar", description: Text("添加存储桶后可以在这里查看占用情况"))
            }
        }
        .navigationTitle("存储占用")
        .hidesToolbarTitle()
    }

    private func content(for connection: Connection, showsPicker: Bool) -> some View {
        let scan = app.storage.scans[connection.id]
        return PageScroll(maxWidth: 1000) {
            PageHeader(title: "存储占用", subtitle: "\(app.connections.folderNames[connection.id] ?? connection.name) · \(connection.storageProvider.displayName)") {
                if showsPicker {
                    bucketPicker(selected: connection)
                }
                Button {
                    app.open(connection.id)
                } label: {
                    Label("浏览文件", systemImage: "folder")
                }
            }
            if let scan, scan.summary.objectCount > 0 || scan.isRunning || scan.error != nil {
                ScanStatusBar(scan: scan) {
                    app.startScan(connection)
                } cancel: {
                    app.storage.cancel(connection.id)
                }
                StatTiles(summary: scan.summary)
                HStack(alignment: .top, spacing: 16) {
                    ChartCard(title: "按文件夹", groups: scan.summary.folderGroups(), total: scan.summary.totalBytes)
                    ChartCard(title: "按文件类型", groups: scan.summary.categoryGroups(), total: scan.summary.totalBytes)
                }
                LargestFiles(objects: scan.summary.largest)
            } else {
                ContentUnavailableView {
                    Label(scan == nil ? "还没有统计「\(app.connections.folderNames[connection.id] ?? connection.name)」" : "存储桶是空的", systemImage: "chart.bar")
                } description: {
                    Text("统计需要列出存储桶里的全部对象，对象很多时会花一些时间，并产生相应的列举请求。")
                } actions: {
                    Button("开始统计") { app.startScan(connection) }
                        .buttonStyle(.borderedProminent)
                        .disabled(app.connections.missingCredentials.contains(connection.id))
                }
                .frame(maxWidth: .infinity)
                .card(padding: 32)
            }
        }
    }

    private func bucketPicker(selected connection: Connection) -> some View {
        Picker("存储桶", selection: Binding(get: { connection.id }, set: { app.dashboardBucketID = $0 })) {
            ForEach(app.connections.connections, id: \.id) { connection in
                Text(app.connections.folderNames[connection.id] ?? connection.name).tag(connection.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

private struct ScanStatusBar: View {
    let scan: StorageModel.Scan
    let rescan: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if scan.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text("正在统计，已读取 \(scan.summary.objectCount.formatted()) 个对象…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("停止", action: cancel)
            } else {
                if let error = scan.error {
                    Label("统计中断：\(error)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if let finishedAt = scan.finishedAt {
                    Text("统计于 \(finishedAt.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("统计已停止，下面是已读取部分的结果")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新统计", action: rescan)
            }
        }
        .font(.callout)
    }
}

private struct StatTiles: View {
    let summary: StorageSummary

    var body: some View {
        HStack(spacing: 16) {
            tile("总大小", summary.totalBytes.formatted(.byteCount(style: .file)), icon: "internaldrive")
            tile("对象数", summary.objectCount.formatted(.number.notation(.compactName)), icon: "doc.on.doc")
            tile("顶层文件夹", summary.topFolderCount.formatted(), icon: "folder")
        }
    }

    private func tile(_ label: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
        }
        .card(padding: 16)
    }
}

/// 单一系列的横向条形图：从大到小，数值标在条末端，悬停显示对象数和占比
private struct ChartCard: View {
    let title: String
    let groups: [StorageSummary.Group]
    let total: Int64
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            if groups.isEmpty {
                Text("暂无数据")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Chart(groups) { group in
                    BarMark(
                        x: .value("大小", group.bytes),
                        y: .value("名称", group.label),
                        height: .fixed(18)
                    )
                    .foregroundStyle(ChartColors.bar)
                    .cornerRadius(4)
                    .opacity(hovered == nil || hovered == group.label ? 1 : 0.4)
                    .annotation(position: .trailing, spacing: 6) {
                        Text(group.bytes.formatted(.byteCount(style: .file)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(group.label)
                    .accessibilityValue("\(group.bytes.formatted(.byteCount(style: .file)))，\(group.count) 个对象")
                }
                // 每根条都标了数值，横轴省掉；右侧留出数值标签的位置
                .chartXAxis(.hidden)
                .chartXScale(range: .plotDimension(endPadding: 72))
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                    }
                }
                .chartYSelection(value: $hovered)
                .frame(height: CGFloat(groups.count) * 30 + 8)

                Text(readout)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(padding: 16)
    }

    private var readout: String {
        guard let hovered, let group = groups.first(where: { $0.label == hovered }) else {
            return "鼠标悬停查看对象数和占比"
        }
        let share = total > 0 ? Double(group.bytes) / Double(total) : 0
        return "\(group.label)：\(group.count.formatted()) 个对象，占 \(share.formatted(.percent.precision(.fractionLength(1))))"
    }
}

private struct LargestFiles: View {
    let objects: [S3Object]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最大的 \(StorageSummary.largestLimit) 个文件")
                .font(.headline)
            if objects.isEmpty {
                Text("暂无数据")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(objects, id: \.key) { object in
                        GridRow {
                            Text(object.key)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Text(object.size.formatted(.byteCount(style: .file)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                        Divider()
                    }
                }
            }
        }
        .card(padding: 16)
    }
}

enum ChartColors {
    /// 单一系列的条形颜色：参考配色里的蓝，浅色和深色各一档，都已校验过对比度
    static let bar = Color(light: 0x2A78D6, dark: 0x3987E5)
}
