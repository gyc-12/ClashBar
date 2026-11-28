## Context

ClashBar 是原生 mihomo 菜单栏面板，所有持久配置改动都必须直接落回原生 YAML 并保留脱离 App 可独立运行的能力。现有 `QuickRuleService` 与 `NativeProxyProviderService` 已经具备原子写入、冲突检查、备份与失败回滚能力。

## Decisions

### 1. 原生文件、运行态与订阅覆盖更新边界
- **独立原生 `dns.ipv6`**：不与顶层运行时 `ipv6` 开关强绑定。读取与写回均针对当前选中的本地原生 YAML 文件的 `dns.ipv6` 字段（若无 `dns` 块则在开启时补齐 `dns: { ipv6: true }`，尽量保留原有注释与其他字段）。保存前经 `mihomo -t` 校验并采用 `QuickRuleService` 原子事务提交；若运行中核心对应当前文件，则重载核心配置（不丢弃其他运行态可编辑项），重载失败自动回滚文件与运行态；核心停止时仅写原生文件。整份配置订阅更新仍可能覆盖该本地改动，与现有提示保持一致。
- **策略组新建与完整编辑**：沿用 `NativeProxyProviderService` 的原生 YAML 事务与 `ProxyProviderProbe` 校验。新建策略组校验唯一名、非保留字、合法类型、有效正则和有效成员来源；自动测速类型（`url-test` / `fallback` / `load-balance`）缺省时写入默认测速 URL 与 `interval: 300`。编辑策略组保留未涉及的原生字段（如 `icon`、`hidden`、`tolerance`、`strategy` 等）；节点匹配预览仅基于当前运行态已加载的节点只读计算，绝不把动态节点写死进 `proxies`。整份订阅覆盖仍可能重置本地策略组修改。
- **默认测速 URL**：属于面板手动测速的本地界面偏好（`UserDefaults`），优先采用策略组原生配置的 `url`，缺省时使用用户设置的默认测速链接，不改写原生配置文件。

### 2. 出口、IPv6 与「为什么连不上」诊断
- 仅在用户主动点击时发起探测，不切换任何策略组、不修改系统代理或原生配置。
- 代理出口 IPv4（`https://ipinfo.io/json`，回退 `https://api.ipify.org?format=json`）与 IPv6（`https://api6.ipify.org?format=json`）仅经当前核心实际代理端口通过 `curl --proxy` 访问，不回退本机直连；本机 IPv6 状态通过读取本机非链路本地（Global / ULA）网卡地址及可选直连状态判断。
- AI 地区可用性在原有 Gemini、ChatGPT 基础上增加 Claude（经核心代理端口检查 `/cdn-cgi/trace` 与页面响应），同样坚持显式拒绝优先、验证页不误报可用。
- 域名排查调用 mihomo 官方 `GET /dns/query?name=<domain>&type=A|AAAA` 获取核心实际 DNS 解析结果（识别 Fake-IP `198.18.0.0/15` 和空 AAAA），并经选定策略组调用 `proxyDelay(..., expected: "200-399")` 验证目标站点 HTTPS 连通性。

### 3. 基础体验与工程收口
- 快捷键：将本地终端命令复制从 `⌘C` 调整为 `⇧⌘C`（保留 `⌥⌘C` 复制当前端点命令），恢复标准 `⌘C` 文本复制。
- 断开连接：连接页顶部 `×` 改为操作菜单，提供「断开当前筛选连接」与带确认弹窗（标明本机/远程目标）的「断开全部连接」。
- 停核引导：核心未运行或远程控制器不可达时，节点页顶部替换为明确的状态卡片与一键启动/重连/前往设置按钮。
- 仓库与打包：应用内更新检查与主页/发布链接统一指向 `gyc-12/ClashBar`；`Scripts/package_app.sh` 优先使用 `swift build --show-bin-path` 定位产物以兼容新版 SwiftPM。
