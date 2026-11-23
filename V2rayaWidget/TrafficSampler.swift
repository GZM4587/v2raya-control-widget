import Foundation

/// 小组件扩展内的单次流量采样器：
/// 登录取 token → 连 /api/message WebSocket → 等第一条 traffic 消息 → 返回。
/// 用于时间线刷新时获取真正实时的数值（扩展进程读 App Group 可能拿到旧缓存）。
enum TrafficSampler {

    struct Sample {
        let up: Int64
        let down: Int64
        let upTotal: Int64
        let downTotal: Int64
    }

    static func sampleOnce() async -> Sample? {
        guard let token = await V2rayAAPI.tokenFromStoredCredentials() else { return nil }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
        guard let url = URL(string: "ws://127.0.0.1:2017/api/message?Authorization=\(encoded)") else { return nil }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 4

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: req)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        // 最多等 3 秒拿第一条 traffic 消息
        let result = await withTimeout(seconds: 3) {
            await TrafficSampler.receiveTraffic(task: task)
        }
        return result ?? nil
    }

    private static func receiveTraffic(task: URLSessionWebSocketTask) async -> Sample? {
        while true {
            let sample: Sample? = await withCheckedContinuation { cont in
                task.receive { result in
                    switch result {
                    case .success(let msg):
                        let text: String
                        switch msg {
                        case .string(let s): text = s
                        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                        @unknown default: text = ""
                        }
                        cont.resume(returning: Self.parse(text))
                    case .failure:
                        cont.resume(returning: nil)
                    }
                }
            }
            if let sample { return sample }
            // 非 traffic 消息（observatory 等）继续等下一条
        }
    }

    private static func parse(_ text: String) -> Sample? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "traffic",
              let body = obj["body"] as? [String: Any]
        else { return nil }

        func num(_ v: Any?) -> Int64? {
            if let i = v as? Int { return Int64(i) }
            if let d = v as? Double { return Int64(d) }
            if let n = v as? NSNumber { return n.int64Value }
            if let s = v as? String, let d = Double(s) { return Int64(d) }
            return nil
        }
        guard let up = num(body["up"]), let down = num(body["down"]) else { return nil }
        return Sample(up: up, down: down,
                      upTotal: num(body["upTotal"]) ?? 0,
                      downTotal: num(body["downTotal"]) ?? 0)
    }

    private static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
