import AppKit
import SwiftUI

/// 独立设置窗口控制器。
/// MenuBarExtra 的弹窗在焦点变化时会连带关闭其 sheet，因此设置界面
/// 必须挂在独立的 NSWindow 上，与菜单栏窗口生命周期解耦。
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = NSHostingView(rootView:
            SettingsView()
                .environmentObject(V2rayaModel.shared)
        )
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 540),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "V2raya Control 设置"
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
