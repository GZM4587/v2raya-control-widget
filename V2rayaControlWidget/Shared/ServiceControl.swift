import Foundation

/// v2rayA 服务（后台守护进程）的启动/停止控制。
/// 通过 ~/v2rayA/v2raya-ctl 脚本执行；主 App 非沙盒，可直接 spawn 子进程。
/// 小组件扩展被沙盒限制无法 spawn，需通过共享文件把请求转交给主 App 补发。
enum ServiceControl {
    static var ctlPath: String { V2rayAStore.installDir + "/v2raya-ctl" }

    static var installed: Bool {
        FileManager.default.isExecutableFile(atPath: ctlPath)
    }

    /// 同步执行 ctl 脚本（App 内请在后台 Task 调用）。
    /// 直接 exec 脚本（依赖其 #!/bin/sh shebang），不经 shell，避免引号/PATH 问题。
    static func run(_ args: [String], timeout: TimeInterval = 90) -> (code: Int32, output: String) {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: ctlPath)
        let isExec = fm.isExecutableFile(atPath: ctlPath)
        guard exists else { return (-1, "诊断: ctl 不存在 path=\(ctlPath)") }
        guard isExec else { return (-1, "诊断: ctl 不可执行(权限) path=\(ctlPath)") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ctlPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (-1, "诊断: spawn 失败 exists=\(exists) isExec=\(isExec) err=\(error)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var output = ""
        let handle = pipe.fileHandleForReading
        while p.isRunning && Date() < deadline {
            let chunk = handle.availableData
            if !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) {
                output += s
            } else {
                usleep(200_000)
            }
        }
        if p.isRunning { p.terminate(); return (-2, output + "\n[超时终止]") }
        let rest = handle.readDataToEndOfFile()
        if let s = String(data: rest, encoding: .utf8) { output += s }
        return (p.terminationStatus, output)
    }

    /// 启动 v2rayA 服务并等待 Web 端口就绪（脚本自带就绪探测，最多约 2 分钟）。
    static func startService() async -> Bool {
        let (code, out) = await Task.detached { run(["start"]) }.value
        if code != 0 {
            await MainActor.run { V2rayaModel.shared.lastError = "启动服务失败：\(out.suffix(200))" }
            return false
        }
        return true
    }

    /// 停止 v2rayA 服务（核心随之退出）。
    static func stopService() async -> Bool {
        let (code, out) = await Task.detached { run(["stop"]) }.value
        if code != 0 {
            await MainActor.run { V2rayaModel.shared.lastError = "停止服务失败：\(out.suffix(200))" }
            return false
        }
        return true
    }
}
