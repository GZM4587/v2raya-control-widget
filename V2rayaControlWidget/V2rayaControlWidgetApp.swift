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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 纯菜单栏应用：不占 Dock、不抢焦点
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            V2rayaModel.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            V2rayaModel.shared.stop()
        }
    }
}
