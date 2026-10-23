import AppKit
import SwiftUI
import SyncCore

extension Color {
    /// 浅色和深色外观各用一个 sRGB 十六进制颜色
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// 界面配色
enum Palette {
    /// 首页、设置页等内容页的底色，和文件表格一致
    static let page = Color(nsColor: .controlBackgroundColor)
    static let card = Color(light: 0xF7F7F8, dark: 0x262628)
    /// 卡片和输入框的细描边
    static let stroke = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.1)
    static let field = Color(light: 0xEFEFF1, dark: 0x2E2E31)
    static let hover = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.06)
    /// 侧栏里自绘行的选中底色，接近系统侧栏的灰色选中
    static let sidebarSelection = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.12)
    static let success = Color(light: 0x1E8E3E, dark: 0x5BD17A)
    static let warning = Color(light: 0xB25E00, dark: 0xFFB454)
}

// MARK: - 页面结构

/// 内容页：可滚动，内容限宽居中
struct PageScroll<Content: View>: View {
    var maxWidth: CGFloat = 860
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.page)
    }
}

/// 页面顶部的大标题，右侧放操作按钮
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            actions
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

extension View {
    /// 圆角卡片：浅底色加细描边
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.stroke))
    }

    /// 内容页的工具栏不重复显示标题（macOS 15 起支持），页面里已经有大标题
    @ViewBuilder
    func hidesToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

/// 设置页、首页里的一组：小标题 + 卡片 + 可选的说明
struct CardSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .card(padding: 0)
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 表单

/// 输入框上方的标签：必填项带红星，右侧可以放灰色提示
struct FieldLabel: View {
    let title: String
    var required = false
    var hint: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            (Text(title) + Text(required ? " *" : "").foregroundStyle(.red))
                .font(.body.weight(.medium))
            Spacer(minLength: 8)
            if let hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// 浅灰填充的圆角输入框，获得焦点时变成白底加描边
struct FilledField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    var isInvalid = false
    var icon: String?
    var height: CGFloat = 36
    /// 有内容时显示清除按钮，按 Esc 也会清空
    var isClearable = false
    /// 需要从外面控制焦点（比如 ⌘F）时传入
    var focus: FocusState<Bool>.Binding?
    @FocusState private var ownFocus: Bool
    @State private var isRevealed = false

    private var focusBinding: FocusState<Bool>.Binding { focus ?? $ownFocus }
    private var isFocused: Bool { focusBinding.wrappedValue }

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
            }
            Group {
                if isSecure && !isRevealed {
                    SecureField("", text: $text, prompt: Text(placeholder))
                } else {
                    TextField("", text: $text, prompt: Text(placeholder))
                }
            }
            .textFieldStyle(.plain)
            .focused(focusBinding)
            .autocorrectionDisabled()
            // 只有可清除的输入框拦截 Esc，表单里的 Esc 仍然用来关闭面板
            .onExitCommand(perform: isClearable ? { text = "" } : nil)
            if isClearable && !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除")
            }
            if isSecure {
                Button {
                    isRevealed.toggle()
                    focusBinding.wrappedValue = true
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isRevealed ? "隐藏" : "显示")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(isFocused ? Palette.page : Palette.field, in: shape)
        .overlay(shape.strokeBorder(borderColor, lineWidth: isFocused || isInvalid ? 1.5 : 1))
        .contentShape(shape)
        .onTapGesture { focusBinding.wrappedValue = true }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    private var borderColor: Color {
        if isInvalid { return .red.opacity(0.8) }
        return isFocused ? Color.accentColor.opacity(0.7) : .clear
    }
}

/// 标签 + 输入框 + 出错时的小字说明
struct LabeledField<Field: View>: View {
    let title: String
    var required = false
    var hint: String?
    var error: String?
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(title: title, required: required, hint: hint)
            field
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - 标识

/// 服务商的彩色圆角方块，里面是缩写或图标
struct ProviderBadge: View {
    let provider: StorageProvider
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(provider.color.gradient)
            .frame(width: size, height: size)
            .overlay {
                if let abbreviation = provider.abbreviation {
                    Text(abbreviation)
                        .font(.system(size: size * (abbreviation.count > 2 ? 0.3 : 0.4), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                } else {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityLabel(provider.displayName)
    }
}

/// 文件列表里的条目类型：文件夹，或按扩展名粗分的文件类型
enum ItemKind: Hashable {
    case folder
    case file(FileCategory)

    static let allKinds: [ItemKind] = [.folder] + FileCategory.allCases.map(ItemKind.file)

    var title: String {
        switch self {
        case .folder: "文件夹"
        case .file(let category): category.rawValue
        }
    }

    var systemImage: String {
        switch self {
        case .folder: "folder"
        case .file(.image): "photo"
        case .file(.video): "film"
        case .file(.audio): "waveform"
        case .file(.document): "doc.text"
        case .file(.code): "chevron.left.forwardslash.chevron.right"
        case .file(.archive): "archivebox"
        case .file(.other): "doc"
        }
    }
}

/// 状态圆点
struct StatusDot: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .fill(isOn ? Palette.success : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
    }
}

extension Date {
    /// 一周内显示「16 小时前」，更早的显示日期
    var friendlyDescription: String {
        if abs(timeIntervalSinceNow) < 7 * 86_400 {
            return formatted(.relative(presentation: .named, unitsStyle: .wide))
        }
        return formatted(date: .abbreviated, time: .omitted)
    }
}
