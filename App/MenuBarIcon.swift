import AppKit
import SwiftUI

/// 菜单栏图标的状态
enum MenuBarIconState: Hashable {
    case idle
    /// 有进行中的上传、改名、删除等
    case syncing
    /// 最近有失败的操作
    case attention
    /// Finder 挂载没开，图标变淡
    case unmounted
}

/// 菜单栏里的 Cooper 图标。状态从 AppModel 读取，变化时自动更新
struct MenuBarLabel: View {
    let app: AppModel

    var body: some View {
        let state = state
        Image(nsImage: MenuBarIcon.image(for: state))
            .accessibilityLabel(accessibilityLabel(state))
    }

    private var state: MenuBarIconState {
        guard app.connections.isMounted else { return .unmounted }
        let ids = app.connectionIDs
        if app.activity.runningCount(connectionIDs: ids) > 0 || app.transfers.activeCount > 0 { return .syncing }
        if app.activity.recentAttentionCount(connectionIDs: ids) > 0 { return .attention }
        return .idle
    }

    private func accessibilityLabel(_ state: MenuBarIconState) -> String {
        switch state {
        case .idle: "Cooper"
        case .syncing: "Cooper，正在同步"
        case .attention: "Cooper，有操作失败"
        case .unmounted: "Cooper，未挂载"
        }
    }
}

/// 生成菜单栏用的模板图：基础图标加右下角的小角标，随系统深浅色变化
@MainActor
enum MenuBarIcon {
    private static var cache: [MenuBarIconState: NSImage] = [:]
    private static let size = NSSize(width: 18, height: 18)

    static func image(for state: MenuBarIconState) -> NSImage {
        if let cached = cache[state] { return cached }
        let image = render(state)
        cache[state] = image
        return image
    }

    private static func render(_ state: MenuBarIconState) -> NSImage {
        guard let base = NSImage(named: "MenuBarIcon") else { return NSImage() }
        let badgeSymbol: String? = switch state {
        case .syncing: "arrow.triangle.2.circlepath"
        case .attention: "exclamationmark"
        case .idle, .unmounted: nil
        }
        guard state == .unmounted || badgeSymbol != nil else { return base }

        let scale = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return base }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let bounds = NSRect(origin: .zero, size: size)
        base.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: state == .unmounted ? 0.45 : 1)

        if let badgeSymbol {
            // 右下角挖一个圆，和图标之间留一圈空隙，再画实心圆和白色（透明）符号
            let badge = NSRect(x: size.width - 9, y: 0, width: 9, height: 9)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 6, weight: .heavy)
            if let symbol = NSImage(systemSymbolName: badgeSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let symbolRect = NSRect(
                    x: badge.midX - symbol.size.width / 2,
                    y: badge.midY - symbol.size.height / 2,
                    width: symbol.size.width,
                    height: symbol.size.height
                )
                symbol.draw(in: symbolRect, from: .zero, operation: .destinationOut, fraction: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }
}
