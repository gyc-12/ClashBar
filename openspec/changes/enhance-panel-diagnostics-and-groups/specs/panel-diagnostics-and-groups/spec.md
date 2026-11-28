## ADDED Requirements

### Requirement: Safe panel shortcuts, connection actions, and stopped-core guidance
面板 SHALL 保留标准 `⌘C` 复制行为，防止误触断开全部连接，并在核心停止或远程不可达时提供明确操作引导。

#### Scenario: Copy selected text without triggering terminal proxy export
- **WHEN** 用户在前台窗口按下 `⌘C`
- **THEN** 触发系统标准复制，而非覆盖剪贴板写入终端代理命令；终端代理命令使用 `⇧⌘C` / `⌥⌘C`

#### Scenario: Close filtered or all connections safely
- **WHEN** 用户在连接页执行断开操作
- **THEN** 断开全部连接需二次确认并标明当前目标；存在筛选词时支持仅断开筛选结果中的连接

#### Scenario: Core is stopped on the Proxy tab
- **WHEN** 本机核心已停止或远程控制器不可达
- **THEN** 节点页顶部显示当前状态与一键启动/重连引导，而不是零值流量卡片

### Requirement: Independent native dns.ipv6 and configurable default test URL
系统设置页 SHALL 提供独立的原生 `dns.ipv6` 开关与可配置的默认手动测速链接（含预设）。

#### Scenario: Toggle native dns.ipv6
- **WHEN** 用户在本地配置中切换原生 `dns.ipv6`
- **THEN** 直接修改原生 YAML 中的 `dns.ipv6` 并经校验提交（运行中重载核心、失败回滚），且不与顶层 `ipv6` 运行时开关相互强制联动

#### Scenario: Configure default latency test URL
- **WHEN** 用户在设置页选择 `gstatic` / `Cloudflare` 预设或输入有效 HTTP/HTTPS 测速链接
- **THEN** 未配置专属 `url` 的策略组与节点手动测速均使用该链接，且不修改原生配置文件

### Requirement: Complete native proxy group creation and configuration
面板 SHALL 支持新建策略组，并在新建或编辑策略组时管理组类型、显式成员、`use` 订阅绑定、`include-all-providers` 以及带实时节点预览的 `filter` / `exclude-filter` 正则。

#### Scenario: Create a filtered automatic group bound to providers
- **WHEN** 用户新建 `url-test` 策略组、绑定提供商并输入过滤正则
- **THEN** 面板实时校验正则并预览当前匹配的运行态节点，保存时校验名称唯一性与有效来源后直接写入原生 `proxy-groups`

#### Scenario: Invalid regex is rejected before saving
- **WHEN** 用户输入语法错误的过滤正则
- **THEN** 面板即时提示正则无效并阻止写入无效配置

### Requirement: Egress, IPv6, AI region, and domain DNS diagnostics
诊断面板 SHALL 支持查看当前代理出口 IPv4/IPv6 与归属 ISP、本机 IPv6 与核心 DNS/Fake-IP 状态、Gemini/ChatGPT/Claude 地区可用性，以及输入任意域名的核心 DNS 查询（A/AAAA）与按组连通性排查。

#### Scenario: Query domain DNS and reachability
- **WHEN** 用户在诊断面板输入域名并运行排查
- **THEN** 分别展示核心 `/dns/query` 返回的 A（含 Fake-IP 标识）与 AAAA 结果以及经所选策略组的 HTTPS 2xx/3xx 连通性，不改变当前节点选择

#### Scenario: Proxy egress check never falls back to direct
- **WHEN** 核心未开放代理端口或代理连接失败
- **THEN** 出口 IP 与 AI 地区检测明确报告端口不可用或失败，不回退本机直连请求
