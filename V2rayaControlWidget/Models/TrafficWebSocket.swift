import Foundation

// WebSocket client for real-time traffic from v2rayA.
// The GUI connects to ws://127.0.0.1:2017/message?Authorization=<jwt>.
// Messages are JSON objects; the ones we care about carry keys such as
// "up", "down", "upTotal", "downTotal" (bytes / bytes per second).
final class TrafficWebSocket {
    private var task: URLSessionWebSocketTask?
    private var receiveWorkItem: DispatchWorkItem?
    private let session: URLSession
    private let onSample: @Sendable (Int64, Int64, Int64, Int64) -> Void
    private let onStateChange: @Sendable (Bool) -> Void
    private var shouldReconnect = true
    private var connected = false

    init(onSample: @escaping @Sendable (Int64, Int64, Int64, Int64) -> Void,
         onStateChange: @escaping @Sendable (Bool) -> Void) {
        self.onSample = onSample
        self.onStateChange = onStateChange
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func connect(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        shouldReconnect = true
        var req = URLRequest(url: url)
        // v2rayA 的鉴权中间件同时支持 query 与 Authorization 头，双保险。
        if let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "Authorization" })?.value {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receiveLoop()
    }

    func disconnect() {
        shouldReconnect = false
        receiveWorkItem?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
    }

    private func setConnected(_ value: Bool) {
        if value != connected {
            connected = value
            onStateChange(value)
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.scheduleReceive(after: 0)
            case .failure:
                self.setConnected(false)
                if self.shouldReconnect {
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReceive(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.receiveLoop() }
        receiveWorkItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleReconnect() {
        scheduleReceive(after: 5)
    }

    // MARK: - Message parsing

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        setConnected(true)

        // v2rayA 协议：信封 {"type":"traffic","body":{"up":…,"down":…,"upTotal":…,"downTotal":…}}
        // up/down 为瞬时速率（bytes/s），upTotal/downTotal 为累计字节。
        guard let type = obj["type"] as? String else { return }
        if type == "traffic", let body = obj["body"] as? [String: Any],
           let up = Self.numericValue(body["up"]), let down = Self.numericValue(body["down"]) {
            let upTotal = Self.numericValue(body["upTotal"]) ?? 0
            let downTotal = Self.numericValue(body["downTotal"]) ?? 0
            onSample(up, down, upTotal, downTotal)
        }
    }

    private static func numericValue(_ v: Any?) -> Int64? {
        if let i = v as? Int { return Int64(i) }
        if let i = v as? Int64 { return i }
        if let d = v as? Double { return Int64(d) }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let d = Double(s) { return Int64(d) }
        return nil
    }
}
