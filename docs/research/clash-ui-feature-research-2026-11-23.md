# Clash / mihomo 客户端功能调研

调研日期：2026-11-23。本文记录候选与实现边界，尚未将这些候选纳入已确认的开发范围。

## 调研方法

- 查询官方 GitHub 仓库元数据、最新 release、README，并阅读相关功能源码。
- stars 表示 GitHub 关注度，不代表安装量或活跃用户数；下表为查询时的快照。
- 源码以本次查询的默认分支提交为准。默认分支中的实现可能先于稳定版，不能将全部源码功能视作稳定版已经交付。
- 与当前 ClashBar 源码和已完成的 OpenSpec 变更对齐，区分已有能力、交互补充和新能力。
- 不访问用户正在使用的核心，不改用户配置，不安装其他客户端。

## 热门及相关项目

| 项目 | stars | 最新发布 | 定位与值得参考的能力 |
| --- | ---: | --- | --- |
| [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) | 159,937 | v2.5.10，11-03 | 桌面客户端；AI / 流媒体检测、可视化规则和组编辑、全局快捷键、WebDAV 备份、系统代理守护 |
| [FlClash](https://github.com/chen08209/FlClash) | 64,751 | v0.9.4，11-19 | 跨平台客户端；请求与 DNS 诊断、配置编辑、桌面全局快捷键、本地 / WebDAV 备份、统一更新状态 |
| [Clash Meta for Android](https://github.com/MetaCubeX/ClashMetaForAndroid) | 50,017 | v2.11.37，11-11 | Android 客户端；按应用接管、配置导入、外部自动化入口 |
| [Clash Party](https://github.com/mihomo-party-org/clash-party) | 27,296 | v2.0.5，11-20 | 桌面客户端；配置覆写、Sub-Store、WebDAV、DNS 设置、Smart Core |
| [Clash Mi](https://github.com/KaringX/clashmi) | 10,664 | v1.0.33.1905，11-22 | 跨平台 mihomo 客户端；简洁操作、内置 zashboard |
| [MetaCubeXD](https://github.com/MetaCubeX/metacubexd) | 4,743 | v1.276.0，11-21 | Web 面板及桌面 / 服务端形态；连接历史、流量归因、多后端；配置管理等能力依赖配套 agent |
| [zashboard](https://github.com/Zephyruso/zashboard) | 3,731 | v3.30.0，10-29 | Web 面板；跨组节点搜索、连接操作、DNS 查询、响应式界面 / PWA |
| [Yacd-meta](https://github.com/MetaCubeX/Yacd-meta) | 817 | v0.8.0，11-17 | 轻量基础面板，可作为信息布局的参考 |

补充参考：[Karing](https://github.com/KaringX/karing) 有 16,304 stars，支持 iCloud、局域网、WebDAV 和 ZIP 备份；它使用修改版 sing-box，适合作为交互参考，不能直接按 mihomo API 移植。[Diodos](https://github.com/Devi766/Diodos) 有 1,438 stars，v0.3.6 为 Alpha，提供吞吐测试、服务可用性检测和节点收藏，适合作为实验功能参考。

## 当前 ClashBar 已有能力

已完成规则原位编辑、自定义规则标识与过滤、搜索策略并更换目标；已增加延迟测量时间 / 年龄 / 历史、组测速参数、规则命中统计、连接详情及规则 / 代理组联动。这些不重复列为新增候选。

原项目已有订阅与定时更新、远程控制器、SSID 配置切换、系统代理 / TUN、DNS / FakeIP 缓存清理、基本连接过滤与关闭、App 前台快捷键。

需要区分的边界：

- `AppViewModel+SystemProxy.swift` 的 `ensureSystemProxyConsistencyOnFirstLaunchIfNeeded` 负责首次启动一致性修复；App 激活时也会刷新状态。这与持续定时重设系统代理的守护不同。
- `AppViewModel+NetworkMonitoring.swift` 已有断网停核、恢复后重新启动和功能恢复。新增统一诊断页有价值，不能把断网恢复当作尚未实现的功能。
- `ConnectionsSnapshot.retainedConnectionLimit` 为 120，连接页也只展示有限数据；面板隐藏时关闭连接流并释放缓存。现有流量展示不能直接作为全天、全应用的完整统计基础。
- 当前 API 服务提供 DNS / FakeIP 缓存清理，尚无主动 DNS 查询界面。

已执行 `make graph`，并通过 CodeGraph explore 检查首次启动代理修复和数据采集策略的调用关系。

## 优先候选

### 1. AI / 服务可用性与出口诊断

收益：延迟低不等于 ChatGPT、Claude、Gemini 或流媒体能正常使用。测试结果应展示服务、状态、可识别的地区和检测时间，并区分可达、地区限制、超时和无法判定。

参考 [Verge 检测器](https://github.com/clash-verge-rev/clash-verge-rev/blob/0218267ed5c9b66ba32bb56602aa144488fae6aa/crates/clash-verge-media-unlock/src/lib.rs) 与 [代理请求入口](https://github.com/clash-verge-rev/clash-verge-rev/blob/0218267ed5c9b66ba32bb56602aa144488fae6aa/src-tauri/src/cmd/media_unlock_checker/mod.rs)。另已确认 v2.5.10 tag 下存在检测页面和检测库。

第一版检测当前分流路径，经本地 mixed-port 发送请求，不自动切换正在使用的节点。Verge 的此入口也使用当前本地代理，不能据此宣称它可以无干扰逐个测试任意节点。首页出口 IP 不能代替每个服务的实际出口；不同域名可能匹配不同规则。可达性也不等于账号登录、API 或付费权限。

复杂度：中。只读检测无需重启核心；远程核心场景必须明确可用的代理入口，控制端口不是流量代理端口。

### 2. 全局快捷键、跨组搜索与收藏

收益：在浏览器或编辑器中直接唤出面板、快速定位组和节点，常用节点可收藏或置顶，支持只看收藏和失效收藏清理。

参考 [FlClash 全局快捷键](https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/lib/manager/hotkey_manager.dart)、[zashboard 跨组搜索](https://github.com/Zephyruso/zashboard/blob/b51d07099e0b18c0c5126cac22ed4e5e01291a1e/src/helper/proxy-search.ts) 与 [Diodos 收藏](https://github.com/Devi766/Diodos/blob/6953f9beeba1ababba2dd3f53e45317f71f49e02/src/components/ProxyNodes.tsx)。快捷键需要反馈注册失败和冲突；录制快捷键时应暂停触发已有操作。

复杂度：低至中。搜索、收藏和快捷键设置为界面偏好，不改 mihomo 规则。节点切换复用现有 API，无需重启核心。

### 3. 配置历史、恢复与订阅更新差异预览

收益：原位编辑已经有隐藏备份文件，但用户缺少历史列表与恢复入口。提供保存 / 更新前快照、差异查看、选择恢复和导出；之后再扩展 WebDAV。

参考 [FlClash 本地 / WebDAV 备份和选择恢复范围](https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/lib/views/backup_and_restore.dart) 与 [Verge 备份历史界面](https://github.com/clash-verge-rev/clash-verge-rev/blob/0218267ed5c9b66ba32bb56602aa144488fae6aa/src/components/setting/mods/backup-history-viewer.tsx)。

“订阅更新差异预览”是面向 ClashBar 原生编辑流程提出的增强，本次没有将它核实为上述客户端的共同现成功能。下载新配置后应明确显示哪些本地编辑将被覆盖，再由用户决定应用；保持原生 YAML，不依赖私有启动合并层。

复杂度：本地历史与恢复为中，WebDAV 另计。创建和查看备份无需重启；恢复当前配置需要校验和应用，不能把完整恢复等同于只读操作。

### 4. 按应用设置分流

收益：直接选择已安装应用或当前连接的进程，为它指定直连、拒绝或代理组。例如 Safari 直连、终端走开发组。

参考 FlClash / Clash Meta for Android 的按应用控制交互；实现采用 macOS 的应用选择器，并生成原生 `PROCESS-NAME` / `PROCESS-PATH` 规则。Android 的 VPN 应用排除通过 VpnService / UID 实现，与 macOS 进程规则不同，不能原样照搬。

复杂度：中。进程识别取决于核心设置与捕获路径，规则仅影响已经进入核心的流量。复用已有原生保存、备份与进程内重载流程，须继续验证真实连接行为。

### 5. DNS 查询与原生 DNS 配置编辑

收益：输入域名查看 A / AAAA / CNAME 等解析结果，辅助判断是否为解析问题；进一步编辑 nameserver、fallback、nameserver-policy、FakeIP 过滤等原生字段。

参考 [zashboard DNS 查询](https://github.com/Zephyruso/zashboard/blob/b51d07099e0b18c0c5126cac22ed4e5e01291a1e/src/components/settings/backend/DnsQuery.vue)。已核实 [mihomo v1.19.31 的 DNS API](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/route/dns.go) 支持 `/dns/query?name=...&type=...`，DNS 禁用时会报错。

[FlClash DNS 事件模型](https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/core/dns_query.go) 直接使用 `mihomo/dns.QueryRecord`，可展示上游、缓存、错误和耗时。这不能证明标准 v1.19.31 REST API 提供完整 DNS 事件历史；实时历史须另查核心版本与事件能力。zashboard 的其他 DNS 诊断标签也按后端能力启用，其中部分为 dae 功能。

复杂度：主动查询低至中，编辑中，完整历史能力待定。查询无需重启；编辑 DNS 属于配置应用，需要单独验证缓存与连接影响。

### 6. 已关闭连接历史与应用流量排行

收益：请求很快结束时仍可回看域名、进程、规则和代理链，查看哪些应用 / 出站消耗流量。

参考 [MetaCubeXD 连接记录及流量归因](https://github.com/MetaCubeX/metacubexd/blob/7d87587a411aca5bfe43852be02969bda0335870/packages/ui/stores/connections.ts)。它将已观测到但从后续连接快照消失的记录保留为关闭历史，并限制保存条数；使用计数差值进行归因。

需要先调整 ClashBar 的 120 条截断与面板隐藏时停止采集的策略。建议可选后台采集、有界缓存、按控制端点隔离，并在界面显示采集时段。普通连接快照仍可能漏掉两次采样之间完成的请求；[FlClash 请求流量实现](https://github.com/chen08209/FlClash/blob/afe7136002271fd64f098b154e7fff40be721eb8/core/request_traffic.go) 使用核心 Tracker 接入，不应承诺仅靠轮询就能完整复制它。

复杂度：中至高。无需重启，但持续采集会增加资源占用，需要明确内存和保留期限。

### 7. 可视化代理组编辑与规则管理补齐

收益：直接编辑 `url-test` / `fallback` 的 URL、interval、tolerance、lazy、成员顺序和 provider；分流页补充原生规则删除、移动和批量更换策略。

参考 [Verge 代理组编辑器](https://github.com/clash-verge-rev/clash-verge-rev/blob/0218267ed5c9b66ba32bb56602aa144488fae6aa/src/components/profile/groups-editor-viewer.tsx)。其编辑界面可参考，但它的 prepend / append / delete 覆写模型与 ClashBar 的原生原位保存定位不同。

复杂度：中至高。保存到原生 `proxy-groups` / `rules`，维护引用并通过核心校验；规则执行顺序与界面按命中数排序必须分开。修改组和重命名的应用行为需要独立验证，不能沿用只改一条规则的连接连续性结论。

## 后续候选

- **统一网络健康页和显式修复**：集中显示控制器、代理入口、DNS、TUN、Helper 和系统代理实际状态；基于现有恢复能力补入口。持续代理守护可选启用，参考 [MetaCubeXD 守护器](https://github.com/MetaCubeX/metacubexd/blob/7d87587a411aca5bfe43852be02969bda0335870/apps/desktop/src/main/sysproxy-guard.ts) 与 [Verge 代理控制](https://github.com/clash-verge-rev/clash-verge-rev/blob/0218267ed5c9b66ba32bb56602aa144488fae6aa/src-tauri/src/core/proxy_control.rs)。恢复 TUN 或重新启动核心可能中断连接，诊断结果应引导用户选择具体操作。
- **手动吞吐 / 抖动测试**：参考 [Diodos speedtest](https://github.com/Devi766/Diodos/blob/6953f9beeba1ababba2dd3f53e45317f71f49e02/src-tauri/src/speedtest.rs)，区分延迟和下载 / 上传吞吐，显示直连或当前代理路径，支持停止。属于消耗流量的显式操作，默认不后台运行。
- **统一维护任务状态**：参考 FlClash v0.9.4 release，把订阅、Geo 资源、核心更新的进度、错误和重试放在统一入口；ClashBar 已有更新操作，增量主要是状态表达。
- **跨设备同步**：可借鉴 Karing 的 iCloud / LAN 交互，但先解决本地历史与恢复。跨设备还涉及路径、核心版本、凭据和并发冲突。

Sub-Store、Smart Core、任意脚本覆写会扩大配置加工和核心依赖范围，暂列低优先级。先完善原生 mihomo 配置的可视化编辑与诊断。

## 建议开发顺序

第一批：全局快捷键 / 跨组搜索 / 收藏；本地配置历史、恢复和订阅更新差异预览；AI / 服务可用性检测。

第二批：应用分流和 DNS 主动查询，再扩展原生 DNS / 代理组编辑。

第三批：有界后台连接历史和应用流量统计；按实际需要加入 WebDAV、网络健康页和吞吐测试。

各项开发前单独确认范围，新增对应 OpenSpec proposal / design / specs / tasks，维护中英文本，并执行适当的 Swift 测试、编译、OpenSpec 校验及独立核心验证。

后续实施记录：用户选择优先开发第 4 项“按应用设置分流”，已完成 `add-application-routing`，使用说明见 [按应用设置分流](../content/docs/application-routing.mdx)。上面的顺序为调研时的建议，不覆盖用户实际选择。

## 源码快照

| 仓库 | 查询提交 |
| --- | --- |
| clash-verge-rev/clash-verge-rev | `0218267ed5c9b66ba32bb56602aa144488fae6aa`（dev） |
| chen08209/FlClash | `afe7136002271fd64f098b154e7fff40be721eb8` |
| MetaCubeX/ClashMetaForAndroid | `6e635124cc72f8c102b7e76d849c384deba28b3f` |
| mihomo-party-org/clash-party | `937bb7f4caef37baa4479faa6b14c26bf4a23235`（smart_core） |
| KaringX/clashmi | `62c15a2fb34fb3b4619a7d01d2a34c22935266f1` |
| MetaCubeX/metacubexd | `7d87587a411aca5bfe43852be02969bda0335870` |
| Zephyruso/zashboard | `b51d07099e0b18c0c5126cac22ed4e5e01291a1e` |
| MetaCubeX/Yacd-meta | `2f7bac07273230638219d02bd61d766c58a2da34` |
| KaringX/karing | `d75fd4ec125e33b04477e23f6df8818c7fe3a350` |
| Devi766/Diodos | `6953f9beeba1ababba2dd3f53e45317f71f49e02` |
