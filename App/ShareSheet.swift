import AppKit
import SwiftUI

enum ShareExpiry: Int, CaseIterable, Identifiable {
    case oneHour = 3600
    case oneDay = 86_400
    case sevenDays = 604_800

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .oneHour: "1 小时"
        case .oneDay: "1 天"
        case .sevenDays: "7 天"
        }
    }
}

private enum ShareKind: Hashable {
    /// 预签名地址：不用公开存储桶，到期自动失效
    case presigned
    /// 公开域名 + key：长期有效，要求存储桶允许公开读取
    case publicURL
}

/// 拷贝分享链接。配置了公开域名的存储桶可以在限时链接和公开链接之间切换。
struct ShareSheet: View {
    let item: BrowserItem
    let browser: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind = ShareKind.presigned
    @State private var expiry = ShareExpiry.oneDay
    @State private var url: URL?
    @State private var copied = false

    private var hasPublicDomain: Bool { browser.connection.publicBaseURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("分享「\(item.name)」")
                .font(.headline)

            if hasPublicDomain {
                Picker("链接类型", selection: $kind) {
                    Text("限时链接").tag(ShareKind.presigned)
                    Text("公开链接").tag(ShareKind.publicURL)
                }
                .pickerStyle(.segmented)
            }
            if kind == .presigned {
                Picker("有效期", selection: $expiry) {
                    ForEach(ShareExpiry.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            Text(url?.absoluteString ?? "")
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                Button(copied ? "已拷贝" : "拷贝链接") { copy() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: generate)
        .onChange(of: expiry) { generate() }
        .onChange(of: kind) { generate() }
    }

    private var caption: String {
        switch kind {
        case .presigned:
            "任何拿到链接的人都能在 \(expiry.title)内下载这个文件，过期后链接失效。"
        case .publicURL:
            "公开链接长期有效，任何人都能访问。存储桶需要已开启公开访问（比如 R2 的公开开发域名或绑定的自定义域名），否则打不开。"
        }
    }

    private func generate() {
        url = switch kind {
        case .presigned: browser.shareURL(for: item, expiresIn: expiry.rawValue)
        case .publicURL: browser.publicURL(for: item)
        }
        copied = false
    }

    private func copy() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copied = true
    }
}
