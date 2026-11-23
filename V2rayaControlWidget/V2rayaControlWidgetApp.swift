import SwiftUI

@main
struct V2rayaControlWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MainView()
                .environmentObject(V2rayaModel.shared)
        } label: {
            Image(systemName: "bolt.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(V2rayaModel.shared.isRunning ? Color.green : Color.red)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var widgetToggleWatcher: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 纯菜单栏应用：不占 Dock、不抢焦点
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            V2rayaModel.shared.start()
        }
        watchWidgetToggleRequests()
    }

    /// 桌面小组件在 App 未运行时会把开关请求写入 App Group，这里轮询并补发。
    private func watchWidgetToggleRequests() {
        var lastHandled = V2rayAStore.currentToggleCounter
        widgetToggleWatcher = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            guard let pending = V2rayAStore.peekPendingToggle(lastHandled: lastHandled) else { return }
            lastHandled = pending.counter
            Task { @MainActor in
                await V2rayaModel.shared.applyDesiredState(pending.desired)
            }
        }
        RunLoop.main.add(widgetToggleWatcher!, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        widgetToggleWatcher?.invalidate()
        Task { @MainActor in
            V2rayaModel.shared.stop()
        }
    }
}
