import Foundation

/// 轻量 v2rayA HTTP 客户端，App 与 Widget 扩展共用。
enum V2rayAAPI {
    static let baseURL = "http://127.0.0.1:2017"

    struct Status {
        var serviceUp: Bool
        var isRunning: Bool
        var version: String
    }

    private struct VersionResponse: Decodable {
        struct Payload: Decodable {
            let version: String?
            let lastKernelExit: String?
        }
        let code: String?
        let data: Payload?
    }

    private struct LoginResponse: Decodable {
        struct Payload: Decodable { let token: String? }
        let code: String?
        let data: Payload?
    }

    private struct ApiResult: Decodable {
        let code: String?
        let message: String?
    }

    static func status(timeout: TimeInterval = 5) async -> Status {
        guard let url = URL(string: "\(baseURL)/api/version") else {
            return Status(serviceUp: false, isRunning: false, version: "—")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        do {
            let (data, _) = try await URLSession(configuration: config).data(from: url)
            let resp = try JSONDecoder().decode(VersionResponse.self, from: data)
            return Status(
                serviceUp: true,
                isRunning: resp.data?.lastKernelExit == "running",
                version: resp.data?.version ?? "—"
            )
        } catch {
            return Status(serviceUp: false, isRunning: false, version: "—")
        }
    }

    static func login(username: String, password: String) async -> String? {
        guard let url = URL(string: "\(baseURL)/api/login") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["username": username, "password": password])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let resp = try JSONDecoder().decode(LoginResponse.self, from: data)
            guard resp.code == "SUCCESS" else { return nil }
            return resp.data?.token
        } catch {
            return nil
        }
    }

    /// 开/停核心。返回 nil 表示成功；否则为错误描述。
    @discardableResult
    static func setCoreRunning(_ running: Bool, token: String) async -> String? {
        guard let url = URL(string: "\(baseURL)/api/v2ray") else { return "bad url" }
        var req = URLRequest(url: url)
        req.httpMethod = running ? "POST" : "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if running { req.httpBody = Data("{}".utf8) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return "auth" }
            if status >= 200 && status < 300 {
                if let result = try? JSONDecoder().decode(ApiResult.self, from: data),
                   result.code == "FAIL" {
                    return result.message ?? "操作失败"
                }
                return nil
            }
            return "HTTP \(status)"
        } catch {
            return error.localizedDescription
        }
    }

    /// 用共享存储里的凭据换取新 token（每次现取，不缓存失败结果）。
    static func tokenFromStoredCredentials() async -> String? {
        guard let creds = V2rayAStore.loadCredentials() else { return nil }
        return await login(username: creds.username, password: creds.password)
    }
}
