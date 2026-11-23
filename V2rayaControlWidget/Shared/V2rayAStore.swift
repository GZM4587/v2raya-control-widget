import Foundation

/// App ↔ Widget 共享存储。
/// 架构：Widget 扩展被 macOS 强制沙盒（pkd 要求），其容器目录
/// ~/Library/Containers/<widget.bundle.id>/Data/ 下 App 侧（非沙盒）可直接写入；
/// 扩展在自己的容器内读取，天然放行，无需 App Group / 门户注册。
enum V2rayAStore {
    /// 每个字段的变化都会整文件重写，数据量小（<50KB）无性能问题
    /// 共享文件绝对路径。
    /// 关键：不能用 homeDirectoryForCurrentUser/NSHomeDirectory()——沙盒扩展里它会被
    /// 重映射到容器内部，导致与 App 写的文件路径不一致。这里用 /Users/<用户名> 绝对构造。
    static let sharedPath: URL = {
        let abs = "/Users/\(NSUserName())/Library/Containers/com.gzm.v2rayactrl2.widget/Data/Library"
        let dir = URL(fileURLWithPath: abs)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("v2raya_snapshot.json")
    }()

    private static let queue = DispatchQueue(label: "v2raya.store")

    // MARK: - Keys / file IO
    private static func loadDict() -> [String: Any] {
        queue.sync {
            guard let data = try? Data(contentsOf: sharedPath),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return obj
        }
    }

    private static func saveDict(_ dict: [String: Any]) {
        queue.sync {
            let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])) ?? Data()
            try? data.write(to: sharedPath, options: .atomic)
        }
    }

    // MARK: - Install dir
    static var defaultInstallDir: String {
        NSHomeDirectory() + "/v2rayA"
    }

    /// v2rayA 安装目录（含末尾 v2raya-ctl 的 BASE），持久化在共享 JSON 里。
    static var installDir: String {
        get {
            let d = loadDict()
            let saved = d["installDir"] as? String
            let dir = (saved?.isEmpty == false) ? saved! : defaultInstallDir
            return dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        }
        set {
            var d = loadDict()
            var v = newValue.hasSuffix("/") ? String(newValue.dropLast()) : newValue
            if v.hasPrefix("~") { v = NSHomeDirectory() + v.dropFirst() }
            d["installDir"] = v
            saveDict(d)
        }
    }

    // MARK: - Snapshot
    struct Snapshot {
        var isRunning: Bool
        var version: String
        var upSpeed: Int64
        var downSpeed: Int64
        var upTotal: Int64
        var downTotal: Int64
        var history: [(date: Date, up: Int64, down: Int64)]
        var lastUpdated: Date?
    }

    static func writeSnapshot(_ s: Snapshot) {
        var d = loadDict()
        d["isRunning"] = s.isRunning
        d["version"] = s.version
        d["upSpeed"] = s.upSpeed
        d["downSpeed"] = s.downSpeed
        d["upTotal"] = s.upTotal
        d["downTotal"] = s.downTotal
        d["lastUpdated"] = Date().timeIntervalSince1970
        let hist: [[Double]] = s.history.prefix(30).map {
            [($0.date.timeIntervalSince1970 * 1000).rounded(), Double($0.up), Double($0.down)]
        }
        d["history"] = hist
        saveDict(d)
    }

    static func readSnapshot() -> Snapshot {
        let d = loadDict()
        var hist: [(Date, Int64, Int64)] = []
        if let arr = d["history"] as? [[Double]] {
            hist = arr.compactMap { row in
                guard row.count >= 3 else { return nil }
                return (Date(timeIntervalSince1970: row[0] / 1000), Int64(row[1]), Int64(row[2]))
            }
        }
        let updated = d["lastUpdated"] as? Double ?? 0
        let num = { (key: String) -> Int64 in
            switch d[key] {
            case let i as Int: return Int64(i)
            case let i64 as Int64: return i64
            case let dbl as Double: return Int64(dbl)
            default: return 0
            }
        }
        return Snapshot(
            isRunning: d["isRunning"] as? Bool ?? false,
            version: d["version"] as? String ?? "—",
            upSpeed: num("upSpeed"),
            downSpeed: num("downSpeed"),
            upTotal: num("upTotal"),
            downTotal: num("downTotal"),
            history: hist,
            lastUpdated: updated > 0 ? Date(timeIntervalSince1970: updated) : nil
        )
    }

    // MARK: - Credentials
    static func saveCredentials(username: String, password: String) {
        var d = loadDict()
        d["credentials"] = [username, password]
        saveDict(d)
    }

    static func loadCredentials() -> (username: String, password: String)? {
        guard let pair = loadDict()["credentials"] as? [String], pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }

    // MARK: - Toggle request (widget → app)
    static func requestToggle(to desiredRunning: Bool) {
        var d = loadDict()
        let n = (d["toggleRequest"] as? Int ?? 0) + 1
        d["toggleRequest"] = n
        d["isRunning"] = desiredRunning
        d["lastUpdated"] = Date().timeIntervalSince1970
        saveDict(d)
    }

    static func peekPendingToggle(lastHandled: Int) -> (counter: Int, desired: Bool)? {
        let d = loadDict()
        let n = d["toggleRequest"] as? Int ?? 0
        guard n > lastHandled else { return nil }
        return (n, d["isRunning"] as? Bool ?? false)
    }

    static var currentToggleCounter: Int {
        loadDict()["toggleRequest"] as? Int ?? 0
    }

    // MARK: - Debug telemetry
    static func writeDebug(_ fields: [String: Any]) {
        var d = loadDict()
        d["debugInfo"] = fields
        saveDict(d)
    }
}
