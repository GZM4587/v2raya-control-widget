import AppIntents
import WidgetKit

/// 小组件按钮动作：优先在主 App 进程内执行真实 API 调用；
/// App 未运行时退化为「写请求 + 乐观更新」，由 App 下次启动时补发。
struct ToggleProxyIntent: AppIntent {
    static var title: LocalizedStringResource = "切换 V2rayA 代理"
    // 关键：必须在扩展进程内执行。主 App 二进制里没有编译此 Intent，
    // openAppWhenRun=true 会导致系统把 Intent 交给 App 而静默失败。
    static var openAppWhenRun = false
    static var isDiscoverable = false

    @Parameter(title: "目标状态")
    var desired: Bool

    init() {}
    init(desired: Bool) { self.desired = desired }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 1) 立即乐观更新共享数据并刷新时间线（按钮观感即时翻转）
        V2rayAStore.requestToggle(to: desired)
        WidgetCenter.shared.reloadAllTimelines()

        // 2) 真实调用 v2rayA API（在小组件扩展进程内执行）
        let st0 = await V2rayAAPI.status(timeout: 3)
        if !st0.serviceUp {
            // 服务未运行：扩展不能 spawn 进程，保留请求并乐观置位，
            // 主 App 的监视器（每 3 秒轮询）会自动拉起服务并执行。
            return .result(dialog: "v2rayA 服务未运行，将在菜单栏 App 中自动启动")
        }

        guard let token = await V2rayAAPI.tokenFromStoredCredentials() else {
            // 服务在但凭据无效：回滚并提示
            let s = V2rayAStore.readSnapshot()
            var rollback = s
            rollback.isRunning = !desired
            V2rayAStore.writeSnapshot(rollback)
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: "请先在菜单栏 ⚡ 组件中登录 v2rayA")
        }

        if let err = await V2rayAAPI.setCoreRunning(desired, token: token) {
            // 失败：回滚乐观状态
            let s = V2rayAStore.readSnapshot()
            var rollback = s
            rollback.isRunning = !desired
            V2rayAStore.writeSnapshot(rollback)
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: err == "auth" ? "登录凭据无效，请在菜单栏组件里重新登录" : "操作失败：\(err)")
        }

        // 3) 成功后拉一次真实状态写回共享数据
        try? await Task.sleep(nanoseconds: 800_000_000)
        let st = await V2rayAAPI.status()
        var snap = V2rayAStore.readSnapshot()
        snap.isRunning = st.isRunning
        snap.version = st.version
        snap.lastUpdated = Date()
        V2rayAStore.writeSnapshot(snap)
        WidgetCenter.shared.reloadAllTimelines()

        return .result(dialog: st.isRunning ? "代理已开启" : "代理已关闭")
    }
}
