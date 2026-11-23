import Foundation
import Combine
import WidgetKit

@MainActor
final class V2rayaModel: ObservableObject {
    static let shared = V2rayaModel()

    // MARK: - Published state
    @Published var isRunning = false          // core 是否在跑
    @Published var serviceUp = false           // v2rayA 服务是否可达
    @Published var wsConnected = false         // 流量 WebSocket 是否已连接
    @Published var version = "—"
    @Published var lastError: String?
    @Published var upSpeed: Int64 = 0          // bytes/s
    @Published var downSpeed: Int64 = 0        // bytes/s
    @Published var upTotal: Int64 = 0          // 累计字节
    @Published var downTotal: Int64 = 0        // 累计字节
    @Published var history: [TrafficPoint] = []
    @Published var needsLogin = false

    // MARK: - Config
    let baseURL = "http://127.0.0.1:2017"

    private let keychainService = "com.gzm.v2raya-control"
    private let credsAccount = "credentials"
    private let maxHistory = 60   // ~5 min at 5s cadence
    private var pollTimer: Timer?
    private var ws: TrafficWebSocket?
    private var loginAttempted = false

    private init() {}

    // MARK: - Keychain (stores username|password so we can re-login when JWT expires)
    private struct StoredCreds { var username: String; var password: String }

    private var storedCreds: StoredCreds? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: credsAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, let str = String(data: data, encoding: .utf8),
                  let sep = str.firstIndex(of: "\u{1F}")
            else { return nil }
            return StoredCreds(username: String(str[str.startIndex..<sep]),
                               password: String(str[str.index(after: sep)...]))
        }
        set {
            deleteKeychain()
            if let newValue {
                let joined = newValue.username + "\u{1F}" + newValue.password
                guard let data = joined.data(using: .utf8) else { return }
                let addQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: keychainService,
                    kSecAttrAccount as String: credsAccount,
                    kSecValueData as String: data,
                ]
                SecItemAdd(addQuery as CFDictionary, nil)
            }
        }
    }

    private func deleteKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: credsAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 当前配置目录下 v2rayA 是否已安装
    var installedNow: Bool { V2rayaInstaller.isInstalled }

    // MARK: - Lifecycle
    func start() {
        Task { await refreshStatus() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatusTask() }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
        ensureTrafficStream()
        startStatsFallback()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopStatsFallback()
        ws?.disconnect()
        ws = nil
    }

    private func refreshStatusTask() {
        Task { await refreshStatus() }
    }

    // MARK: - Status polling (public endpoint, no auth needed)
    func refreshStatus() async {
        guard let url = URL(string: "\(baseURL)/api/version") else { return }
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            let (data, _) = try await URLSession(configuration: config).data(from: url)
            struct VersionResponse: Decodable {
                struct Payload: Decodable {
                    let version: String?
                    let lastKernelExit: String?
                }
                let code: String?
                let data: Payload?
            }
            let resp = try JSONDecoder().decode(VersionResponse.self, from: data)
            serviceUp = true
            version = resp.data?.version ?? "—"
            isRunning = (resp.data?.lastKernelExit == "running")
            lastError = nil
            publishToWidget()
            ensureTrafficStream()
        } catch {
            serviceUp = false
            isRunning = false
            lastError = "无法连接 v2rayA（\(baseURL)）：请确认服务已启动"
            publishToWidget(force: true)
            dropTrafficStream()
        }
    }

    // MARK: - Toggle proxy on/off
    /// 应用小组件请求的目标状态（与当前状态一致则跳过；服务未运行则先拉起服务）。
    func applyDesiredState(_ desired: Bool) async {
        if desired && !serviceUp {
            guard await startServiceIfNeeded() else { return }
        }
        await refreshStatus()
        guard isRunning != desired else { return }
        await toggleCore()
    }

    /// 服务未运行时通过 v2raya-ctl 拉起，并等待就绪。
    func startServiceIfNeeded() async -> Bool {
        guard !serviceUp else { return true }
        lastError = nil
        let ok = await ServiceControl.startService()
        // 服务就绪后再确认一次状态
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await refreshStatus()
        if ok && serviceUp {
            // 首次拉起后需要重新登录（JWT 由服务签发）
            if cachedToken != nil { cachedToken = nil; tokenExpiry = .distantPast }
            _ = await accessToken()
        }
        return serviceUp
    }

    /// 启动/停止 v2rayA 服务本体（停止会连带停掉代理核心）。
    func toggleService() async {
        if serviceUp {
            dropTrafficStream()
            let ok = await ServiceControl.stopService()
            if ok {
                serviceUp = false
                isRunning = false
                lastError = nil
                publishToWidget(force: true)
            }
        } else {
            guard await startServiceIfNeeded() else { return }
            publishToWidget(force: true)
        }
    }

    func toggleCore() async {
        // 服务没起来时，先拉起服务再开核心
        if !serviceUp {
            guard isRunning == false else { return }
            guard await startServiceIfNeeded() else {
                needsLogin = serviceUp // 服务起来了但没凭据才要求登录
                return
            }
        }
        guard let token = await accessToken() else {
            needsLogin = true
            return
        }
        let method = isRunning ? "DELETE" : "POST"
        guard let url = URL(string: "\(baseURL)/api/v2ray") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method == "POST" { req.httpBody = Data("{}".utf8) }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                // JWT expired — clear and retry once with fresh login
                cachedToken = nil
                if let fresh = await accessToken(), !fresh.isEmpty, fresh != token {
                    var retry = req
                    retry.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                    _ = try? await URLSession.shared.data(for: retry)
                } else {
                    needsLogin = true
                    lastError = "登录失败，请检查账号密码"
                }
            } else if status >= 200 && status < 300 {
                struct ApiResult: Decodable { let code: String?; let message: String? }
                if let result = try? JSONDecoder().decode(ApiResult.self, from: data),
                   result.code == "FAIL" {
                    lastError = result.message ?? "操作失败"
                } else {
                    lastError = nil
                }
            } else {
                lastError = "HTTP \(status)"
            }
            // The kernel takes a moment to flip state; re-poll shortly after.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
        ensureTrafficStream()
    }

    // MARK: - Login / token cache
    private var cachedToken: String?
    private var tokenExpiry = Date.distantPast

    func login(username: String, password: String) async -> Bool {
        await _login(username: username, password: password)
    }

    private func _login(username: String, password: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/login") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["username": username, "password": password])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct LoginResponse: Decodable {
                struct Payload: Decodable { let token: String? }
                let code: String?
                let data: Payload?
            }
            let resp = try JSONDecoder().decode(LoginResponse.self, from: data)
            if resp.code == "SUCCESS", let token = resp.data?.token {
                cachedToken = token
                tokenExpiry = Date().addingTimeInterval(6 * 3600) // conservative TTL
                storedCreds = StoredCreds(username: username, password: password)
                V2rayAStore.saveCredentials(username: username, password: password)
                needsLogin = false
                lastError = nil
                ensureTrafficStream()
                return true
            } else {
                lastError = "用户名或密码错误"
            }
        } catch {
            lastError = error.localizedDescription
        }
        return false
    }

    private func accessToken() async -> String? {
        if let cachedToken, Date() < tokenExpiry { return cachedToken }
        if let creds = storedCreds {
            if await _login(username: creds.username, password: creds.password) {
                return cachedToken
            }
        } else if !loginAttempted {
            loginAttempted = true
            needsLogin = true
        }
        return nil
    }

    // MARK: - Traffic stream
    private var wsStarting = false

    private func ensureTrafficStream() {
        guard serviceUp, jwtAvailableForWS, ws == nil, !wsStarting else { return }
        wsStarting = true
        Task {
            let token: String?
            if let cachedToken, Date() < tokenExpiry {
                token = cachedToken
            } else if let creds = storedCreds {
                _ = await _login(username: creds.username, password: creds.password)
                token = cachedToken
            } else {
                token = nil
            }
            wsStarting = false
            guard let token, ws == nil, serviceUp else { return }
            let client = TrafficWebSocket { [weak self] up, down, upTotal, downTotal in
                Task { @MainActor in self?.recordSample(up: up, down: down, upTotal: upTotal, downTotal: downTotal) }
            } onStateChange: { [weak self] connected in
                Task { @MainActor in self?.wsConnected = connected }
            }
            ws = client
            client.connect(urlString: Self.wsURL(token: token))
        }
    }

    private static func wsURL(token: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
        // 与官方前端一致：/api/message?Authorization=<jwt>
        return "ws://127.0.0.1:2017/api/message?Authorization=\(encoded)"
    }

    private var jwtAvailableForWS: Bool {
        cachedToken != nil || storedCreds != nil
    }

    private func dropTrafficStream() {
        ws?.disconnect()
        ws = nil
        wsConnected = false
        upSpeed = 0
        downSpeed = 0
    }

    /// WS 未连上时（如尚未登录），用 HTTP 兜底：轮询 /api/stats/traffic。
    private var fallbackTimer: Timer?

    private func startStatsFallback() {
        guard fallbackTimer == nil else { return }
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollStatsHTTP() }
        }
        RunLoop.main.add(fallbackTimer!, forMode: .common)
    }

    private func stopStatsFallback() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func pollStatsHTTP() async {
        guard !wsConnected, serviceUp, let token = cachedToken, Date() < tokenExpiry else { return }
        guard let url = URL(string: "\(baseURL)/api/stats/traffic") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        struct StatsResp: Decodable {
            struct Body: Decodable { let up: Int64?; let down: Int64?; let upTotal: Int64?; let downTotal: Int64? }
            let type: String?
            let body: Body?
        }
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let resp = try? JSONDecoder().decode(StatsResp.self, from: data),
           let body = resp.body, resp.type == "traffic" {
            recordSample(up: body.up ?? 0, down: body.down ?? 0,
                         upTotal: body.upTotal ?? 0, downTotal: body.downTotal ?? 0)
        }
    }

    private var wsSampleCount = 0
    // 差分基准：瞬时 up/down 字段波动极大（多为 0），改用累计字节差分计算速率
    private var lastUpTotal: Int64?
    private var lastDownTotal: Int64?
    private var lastSampleTime: Date?

    private func recordSample(up: Int64, down: Int64, upTotal: Int64, downTotal: Int64) {
        let now = Date()
        if let lt = lastSampleTime, let pu = lastUpTotal, let pd = lastDownTotal {
            let dt = now.timeIntervalSince(lt)
            let du = upTotal - pu
            let dd = downTotal - pd
            if dt > 0.2, du >= 0, dd >= 0, dt < 30 {
                // 正常窗口：速率 = 累计字节差 / 时间差
                upSpeed = Int64((Double(du) / dt).rounded())
                downSpeed = Int64((Double(dd) / dt).rounded())
            } else {
                // 服务重启导致计数器清零，或长时间无样本：重置基准
                upSpeed = 0
                downSpeed = 0
            }
        }
        lastUpTotal = upTotal
        lastDownTotal = downTotal
        lastSampleTime = now
        self.upTotal = upTotal
        self.downTotal = downTotal
        history.append(TrafficPoint(date: now, up: upSpeed, down: downSpeed))
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
        // 遥测：App 端 WS 收到的原始样本
        wsSampleCount += 1
        if wsSampleCount % 10 == 1 {
            V2rayAStore.writeDebug([
                "source": "app-ws",
                "samples": wsSampleCount,
                "up": up, "down": down,
                "upTotal": upTotal, "downTotal": downTotal,
                "time": Date().formatted(date: .omitted, time: .standard),
            ])
        }
        publishToWidget()
    }

    /// 把最新快照写入 App Group，并请求 WidgetKit 刷新桌面组件。
    /// 节流：距上次 reload ≥ 15 秒才发，避免耗尽时间线预算。
    private var lastWidgetReload = Date.distantPast
    private var lastWidgetWrite = Date.distantPast

    func publishToWidget(force: Bool = false) {
        let now = Date()
        let shouldWrite = force || now.timeIntervalSince(lastWidgetWrite) >= 5
        let shouldReload = force || now.timeIntervalSince(lastWidgetReload) >= 15
        guard shouldWrite || shouldReload else { return }

        if shouldWrite {
            lastWidgetWrite = now
            let snap = V2rayAStore.Snapshot(
                isRunning: isRunning,
                version: version,
                upSpeed: upSpeed,
                downSpeed: downSpeed,
                upTotal: upTotal,
                downTotal: downTotal,
                history: history.map { ($0.date, $0.up, $0.down) },
                lastUpdated: Date()
            )
            V2rayAStore.writeSnapshot(snap)
        }
        if shouldReload {
            lastWidgetReload = now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Helpers
    func formatBytes(_ bytes: Int64, perSecond: Bool = false) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        let plainUnits = ["B", "KB", "MB", "GB"]
        let table = perSecond ? units : plainUnits
        var value = Double(max(0, bytes))
        var i = 0
        while value >= 1024 && i < table.count - 1 { value /= 1024; i += 1 }
        if value < 10 && i > 0 {
            return String(format: "%.1f %@", value, table[i])
        }
        return String(format: "%.0f %@", value, table[i])
    }
}

struct TrafficPoint: Identifiable {
    let id = UUID()
    let date: Date
    let up: Int64
    let down: Int64
}
