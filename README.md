# V2rayA Control（菜单栏 App + 桌面小组件）

macOS 双形态客户端，连接本机 `~/v2rayA` 的 v2rayA 服务：

- **菜单栏 ⚡ App**：登录、开关代理、实时流量曲线与上下行数值
- **WidgetKit 桌面小组件「V2rayA 代理」**（中等尺寸）：
  - ▶️/⏹ 交互式开关按钮（AppIntent，点击直接切换代理）
  - 下行绿 / 上行蓝双曲线（最近约 5 分钟）+ 实时速率数值
  - 状态灯：绿=运行 / 红=停止 / 灰=服务离线

## 项目结构

```
V2rayaControlWidget.xcodeproj          # Xcode 工程（两个 target）
├── V2rayaControlWidget/               # 主 App（菜单栏，LSUIElement）
│   ├── V2rayaControlWidgetApp.swift   # MenuBarExtra + 小组件开关请求补发监视器
│   ├── Models/V2rayaModel.swift       # 轮询/开关/登录/WebSocket 采样 → 写 App Group
│   ├── Models/TrafficWebSocket.swift  # /message 实时流量
│   ├── Shared/V2rayAStore.swift       # App Group 共享数据（快照/凭据/开关请求）
│   └── Shared/V2rayAAPI.swift         # App/Widget 共用 HTTP 客户端
└── V2rayaWidget/                      # Widget Extension（.appex）
    ├── V2rayAWidget.swift             # TimelineProvider + 交互视图 + 曲线绘制
    └── ToggleProxyIntent.swift        # AppIntent：乐观更新 + 真实 API 调用 + 失败回滚
```

## 添加桌面小组件

1. 确保 `~/Applications/V2raya Control.app` 正在运行（菜单栏有 ⚡）。
2. 在菜单栏 ⚡ 弹窗里登录一次 v2rayA 账号（凭据同步进 App Group，组件按钮才有权限）。
3. 桌面空白处右键 → 「编辑小组件…」→ 搜索 **「V2rayA 代理」** → 拖到桌面。
4. 若列表未出现：注销重登或等 1–2 分钟让 WidgetGallery 刷新缓存。

## 构建安装

```sh
# 注意：项目在 iCloud 目录会导致 codesign 报 detritus 错误，
# 需构建到中立路径再 ditto 安装：
xcodebuild -project V2rayaControlWidget.xcodeproj -scheme V2rayaControlWidget \
  -configuration Release -derivedDataPath /tmp/v2raya-dd build
rm -rf "$HOME/Applications/V2raya Control.app"
ditto "/tmp/v2raya-dd/Build/Products/Release/V2raya Control.app" \
      "$HOME/Applications/V2raya Control.app"
xattr -cr "$HOME/Applications/V2raya Control.app"
open "$HOME/Applications/V2raya Control.app"
```

## 技术要点

| 功能 | 接口 | 认证 |
| --- | --- | --- |
| 运行状态 | `GET /api/version` → `data.lastKernelExit == "running"` | 无需 |
| 开/关核心 | `POST /api/v2ray` / `DELETE /api/v2ray` | `Authorization: Bearer <JWT>` |
| 登录取 JWT | `POST /api/login` `{username,password}` | — |
| 实时流量 | `ws://127.0.0.1:2017/message?Authorization=<JWT>`，JSON 含 `up`/`down` | query 参数 |

- App ↔ Widget 通过 **App Group**（`group.com.gzm.v2raya-control`）共享快照、凭据与待处理开关请求。
- 小组件按钮 = `Button(intent:)`（macOS 14+ 交互式小组件），`openAppWhenRun=true` 让 Intent 在宿主 App 进程执行完整网络调用；App 未运行时写入请求、由 App 下次启动补发。
- 时间线刷新节流：App 侧 ≥15s 才 reloadAllTimelines；组件自动刷新 10 分钟/次（系统预算约 40–70 次/天）。
- 部署目标 macOS 14+；签名 Team `547386NZF6`，App/扩展均启用 Sandbox + App Groups + 网络客户端权限。
