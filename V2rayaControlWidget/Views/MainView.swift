import SwiftUI

/// MenuBarExtra 的弹窗不是 keyWindow，NSApp.keyWindow 拿不到它；
/// 用一个挂在视图树里的 NSView 直接捕获宿主 window 引用。
final class PopupWindowHolder {
    static weak var window: NSWindow?
}

private struct WindowFinder: NSViewRepresentable {
    final class FinderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            PopupWindowHolder.window = window
        }
    }
    func makeNSView(context: Context) -> NSView { FinderView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 菜单栏弹出窗口主界面：状态 + 开关 + 流量曲线与上下行数值。
struct MainView: View {
    @EnvironmentObject var model: V2rayaModel
    @State private var showLogin = false
    @State private var username = ""
    @State private var password = ""
    @State private var loggingIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            Divider()
            trafficSection
            Divider()
            actionButtons
            if let err = model.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(WindowFinder())
        .onAppear {
            if model.needsLogin { showLogin = true }
        }
        .sheet(isPresented: $showLogin) { loginSheet }
    }

    // MARK: - Status
    private var statusRow: some View {
        HStack(spacing: 8) {
            // 关闭弹窗按钮（窗体左上角）
            Button {
                // 语义 = 退出程序：收起弹窗并结束进程（菜单栏图标随之消失）
                PopupWindowHolder.window?.orderOut(nil)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Color.secondary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help("退出 V2raya Control")

            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("v\(model.version)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var dotColor: Color {
        if !model.serviceUp { return .gray }
        return model.isRunning ? .green : .red
    }

    private var statusText: String {
        if !model.serviceUp { return "服务未连接" }
        return model.isRunning ? "代理运行中" : "代理已停止"
    }

    // MARK: - Traffic
    private var trafficSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                Text("下行")
                Spacer()
                Text(model.formatBytes(model.downTotal))          // 累计
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(model.formatBytes(model.downSpeed, perSecond: true))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(Color(red: 0.25, green: 0.55, blue: 1.0))
                Text("上行")
                Spacer()
                Text(model.formatBytes(model.upTotal))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(model.formatBytes(model.upSpeed, perSecond: true))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            TrafficChart(points: model.history)
            HStack {
                Text(model.wsConnected ? "实时数据（WebSocket）" : "等待连接…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    // MARK: - Actions
    private var actionButtons: some View {
        VStack(spacing: 8) {
            if model.serviceUp {
                // 服务在跑：正常的核心开/关按钮
                HStack(spacing: 10) {
                    Button {
                        Task { await model.toggleCore() }
                    } label: {
                        Text(model.isRunning ? "停止代理" : "启动代理")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isRunning ? .red : .accentColor)

                    Button {
                        NSWorkspace.shared.open(URL(string: model.baseURL)!)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.bordered)
                    .help("打开 v2rayA 面板")

                    Button {
                        SettingsWindowController.shared.show()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .help("设置：安装路径 / 账号")
                }
                HStack {
                    // 服务级停止（连带停核心）：仅在核心已停止时提供，避免误触
                    if !model.isRunning {
                        Button {
                            Task { await model.toggleService() }
                        } label: {
                            Label("停止 v2rayA 服务", systemImage: "power.dotted")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    Spacer()
                }
            } else {
                // 服务未运行：主按钮变为拉起服务
                HStack(spacing: 10) {
                    Button {
                        Task { await model.toggleService() }
                    } label: {
                        Label(model.installedNow ? "启动 v2rayA 服务" : "下载并安装 v2rayA",
                              systemImage: model.installedNow ? "play.fill" : "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        SettingsWindowController.shared.show()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .help("设置：安装路径 / 下载安装 / 账号")

                }
            }
        }
    }

    // MARK: - Login sheet
    private var loginSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("v2rayA 登录")
                .font(.headline)
            Text("用于开/关代理与控制实时流量推送。账号密码仅存于本机钥匙串。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("用户名", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder)
            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("取消") { showLogin = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(loggingIn ? "登录中…" : "登录并保存") {
                    loggingIn = true
                    Task {
                        let ok = await model.login(username: username, password: password)
                        await MainActor.run {
                            loggingIn = false
                            if ok {
                                password = ""
                                showLogin = false
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(loggingIn || username.isEmpty || password.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
