import AppKit
import SwiftUI

/// 所有上传、下载任务，最新的在最上面。
struct TransfersView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let manager = app.transfers
        Group {
            if manager.transfers.isEmpty {
                ContentUnavailableView("没有传输任务", systemImage: "arrow.up.arrow.down", description: Text("上传和下载的进度会显示在这里"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.page)
            } else {
                PageScroll {
                    PageHeader(title: "传输", subtitle: subtitle(manager)) {
                        Button("清除已结束") { manager.clearFinished() }
                            .disabled(!manager.hasFinished)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(manager.transfers.enumerated()), id: \.element.id) { index, transfer in
                            if index > 0 {
                                Divider()
                                    .padding(.leading, 60)
                            }
                            TransferRow(transfer: transfer)
                        }
                    }
                    .card(padding: 0)
                }
            }
        }
        .navigationTitle("传输")
        .hidesToolbarTitle()
    }

    private func subtitle(_ manager: TransferManager) -> String {
        let active = manager.activeCount
        return active > 0 ? "\(active) 个进行中，共 \(manager.transfers.count) 个" : "共 \(manager.transfers.count) 个，全部已结束"
    }
}

private struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.direction == .upload ? "arrow.up" : "arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var tint: Color {
        switch transfer.state {
        case .failed: .red
        case .cancelled: .secondary
        case .completed: Palette.success
        case .running: Color.accentColor
        }
    }

    @ViewBuilder
    private var status: some View {
        switch transfer.state {
        case .running:
            // Progress 不会通知 SwiftUI，定时读取
            TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                let progress = transfer.progress
                let total = progress.totalUnitCount
                let done = Int64(progress.fractionCompleted * Double(total))
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: progress.fractionCompleted)
                    Text("\(done.formatted(.byteCount(style: .file))) / \(total.formatted(.byteCount(style: .file))) · \(transfer.location)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .completed:
            Text("已完成 · \(transfer.location)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .cancelled:
            Text("已取消 · \(transfer.location)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text("失败：\(message)")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if transfer.state == .running {
            Button {
                transfer.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("取消")
        } else if let url = transfer.localURL {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url.resolvingSymlinksInPath()])
            } label: {
                Image(systemName: "magnifyingglass.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
        }
    }
}
