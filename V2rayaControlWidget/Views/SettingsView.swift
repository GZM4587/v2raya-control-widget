import SwiftUI

/// ⚙️ 设置面板：安装路径 / 自动下载安装 / 用户名密码
struct SettingsView: View {
    @EnvironmentObject var model: V2rayaModel

    @State private var installDir = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var status: String = ""
    @State private var saveOk = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置")
                .font(.headline)

            // MARK: 安装路径
            GroupBox(label: Label("v2rayA 安装路径", systemImage: "folder")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("/Users/\(NSUserName())/v2rayA", text: $installDir)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Button("选择…") { chooseDirectory() }
                            .help("弹出目录选择框")
                    }
                    HStack {
                        Button("恢复默认路径") {
                            installDir = V2rayAStore.defaultInstallDir
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        Spacer()
                        Text(installedMark)
                            .font(.caption2)
                            .foregroundStyle(installedNow ? .green : .orange)
                    }
                    Button {
                        saveDir()
                        Task { await runInstall() }
                    } label: {
                        Text(busy ? status : "下载最新版并安装到以上路径")
                    }
                    .disabled(busy)
                    if !status.isEmpty {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text("首次启动服务时会自动下载 geoip/geosite 规则数据。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            // MARK: 凭据
            GroupBox(label: Label("v2rayA 管理账号", systemImage: "person.badge.key")) {
                VStack(spacing: 6) {
                    TextField("用户名", text: $username)
                        .textFieldStyle(.roundedBorder)
                    SecureField("密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        if saveOk {
                            Text("已保存 ✓").font(.caption).foregroundStyle(.green)
                        }
                        if let e = model.lastError, !saveOk {
                            Text(e).font(.caption).foregroundStyle(.red).lineLimit(1)
                        }
                        Spacer()
                        Button("保存并登录") {
                            Task {
                                let ok = await model.login(username: username, password: password)
                                saveOk = ok
                                if ok { password = "" }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(username.isEmpty || password.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("关闭") { SettingsWindowController.shared.window?.performClose(nil) }
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            installDir = V2rayAStore.installDir
            if let c = V2rayAStore.loadCredentials() { username = c.username }
        }
    }

    private var installedNow: Bool {
        let dir = installDir.isEmpty ? V2rayAStore.installDir : installDir
        return FileManager.default.isExecutableFile(atPath: dir + "/bin/v2raya")
    }

    private var installedMark: String {
        installedNow ? "已安装 ✓" : "未安装"
    }

    /// 弹出目录选择框；未选中则不修改
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: installDir.isEmpty
            ? V2rayAStore.defaultInstallDir : installDir)
        panel.message = "选择 v2rayA 的安装目录（不存在可在此新建）"
        if panel.runModal() == .OK, let url = panel.url {
            installDir = url.path
        }
    }

    private func saveDir() {
        let dir = installDir.trimmingCharacters(in: .whitespaces)
        if !dir.isEmpty { V2rayAStore.installDir = dir }
    }

    private func runInstall() {
        saveDir()
        busy = true
        status = "准备…"
        Task {
            do {
                // 下载前先比对版本：相同则不必升级
                let latest = try await V2rayaInstaller.latestVersion()
                let installed = V2rayaInstaller.installedVersion()
                if let installed, installed == latest {
                    await MainActor.run {
                        status = "已是最新版本 v\(installed)，无需下载升级 ✓"
                        busy = false
                    }
                    return
                }
                await MainActor.run {
                    status = "准备升级 v\(installed ?? "未安装") → v\(latest)…"
                }
                try await V2rayaInstaller.install { p in
                    Task { @MainActor in
                        status = p.phase + (p.detail.isEmpty ? "" : " · \(p.detail)")
                    }
                }
                await MainActor.run {
                    status = "安装完成 ✓ (v\(latest)) 请点「启动 v2rayA 服务」"
                    busy = false
                    model.objectWillChange.send()
                }
                await V2rayaModel.shared.refreshStatus()
            } catch {
                await MainActor.run {
                    status = "安装失败：\(error.localizedDescription)"
                    busy = false
                }
            }
        }
    }
}
