import AppKit
import SwiftUI

@main
struct CooperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let app = delegate.app
        Window("Cooper", id: "main") {
            MainView()
                .environment(app)
                .frame(minWidth: 880, minHeight: 540)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            // 设置是主窗口里的一页，不再单独开窗口
            CommandGroup(replacing: .appSettings) {
                MainWindowCommand(title: "设置…", key: ",", app: app) { $0.selection = .settings }
            }
            CommandGroup(replacing: .newItem) {
                MainWindowCommand(title: "添加存储桶…", key: "n", app: app) { $0.addConnection() }
            }
        }

        // 常驻菜单栏：挂载状态和文件操作记录
        MenuBarExtra {
            MenuBarPanel()
                .environment(app)
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 主窗口关掉后 App 继续留在菜单栏，挂载的定时提醒照常运行。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app: AppModel

    override init() {
        app = AppModel()
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 启动时的 Apple Event 只在这里能读到
        app.launchedAtLogin = Self.isLaunchedAsLoginItem()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private static func isLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}

/// Dock 图标：主窗口开着时显示；关掉后按设置隐藏，只留菜单栏图标
enum DockIcon {
    static let hidesWhenClosedKey = "hideDockIconWhenMainWindowClosed"

    static var hidesWhenClosed: Bool {
        UserDefaults.standard.object(forKey: hidesWhenClosedKey) as? Bool ?? true
    }

    @MainActor
    static func show() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    @MainActor
    static func mainWindowClosed() {
        if hidesWhenClosed {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

extension OpenWindowAction {
    /// 打开主窗口并带到前面。从菜单栏打开时 Dock 图标可能是隐藏的，先恢复
    @MainActor
    func showMainWindow() {
        DockIcon.show()
        self(id: "main")
        NSApp.activate()
    }
}

/// 菜单命令：先把主窗口带到前面（关掉了就重新打开），再执行操作
private struct MainWindowCommand: View {
    let title: String
    let key: KeyEquivalent
    let app: AppModel
    let action: (AppModel) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow.showMainWindow()
            action(app)
        }
        .keyboardShortcut(key, modifiers: .command)
    }
}
