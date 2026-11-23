# 代理提供商管理调研

日期：2026-11-23。目标版本沿用此前独立测试所用 mihomo v1.19.31；从调研到实现验证均未修改用户配置或控制用户运行中的核心。

## 上一会话与当前需求

此前已完成原生规则编辑、分流诊断与应用分流；用户关注配置可以脱离 App 运行，以及配置热重载对已有连接的影响。本轮新增提供商订阅的快速增删、启停和链接修改。

普通规则测试验证过 PID 和 loopback 长 TCP，但不能据此声称经代理提供商的连接也持续传输。本次需要覆盖核心对 providerChains 的处理。

## 固定版本源码

| 来源 | 核对结果 | 对方案的影响 |
| --- | --- | --- |
| [provider schema](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/adapter/provider/parser.go) | 支持 type / url / path / filter / exclude-filter / health-check 等，没有 enabled / disabled | 停用必须改变原生有效定义或引用，不能添加无效开关字段 |
| [provider REST route](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/route/provider.go) | 提供 GET、PUT 更新与健康检查，没有增删或源链接编辑 | 配置文件是管理来源，远程标准 API 不能完成完整管理 |
| [provider implementation](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/adapter/provider/provider.go) | providerForApi 没有 URL；NewProxiesParser 拒绝零节点；HTTP / file 的 Initial 调用 closeAllConnections，按 ProviderChains 中的同名项关闭连接 | 需要文件模型；排除全部节点不能作为可靠停用；连接影响需独立验收 |
| [group parser](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/adapter/outboundgroup/parser.go) | include-all 启用两种自动引入，include-all-providers 使用 AllProviders 覆盖 use；无 use / proxies 来源时可报错，空成员还有 empty-fallback | 单独删除 use 不够；需要依赖与空组处理 |
| [config parser](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/config/config.go) | parseProxies 构造提供商定义和组；HTTP 内容初始化发生在应用阶段 | 结构校验通过不能证明订阅内容已加载 |
| [config executor](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/executor/executor.go) | ApplyConfig 调用 loadProvider，对新配置保留的提供商逐一 Initial；加载失败记录日志 | 影响可能覆盖其他提供商；PUT 成功仍须核验实际加载 |
| [resource fetcher](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/component/resource/fetcher.go) | Initial 优先读取已有 path 缓存；Update 才读取 vehicle | 仅改 URL 可能继续显示旧源，需要新缓存来源和实际下载检查 |

官方字段说明：[代理集合](https://wiki.metacubex.one/config/proxy-providers/)与[代理组](https://wiki.metacubex.one/config/proxy-groups/)。实现边界以固定版本源码为依据，当前在线文档可能包含后续字段。

## 开源面板对照

这里比较同一份配置里的 `proxy-providers`。整份配置订阅的增删改，以及刷新已经存在的提供商，分别是另外两类操作。

| 项目 | 已核实的提供商操作 | 停用与保存方式 |
| --- | --- | --- |
| OpenClash | [提供商列表可增删、启停](https://github.com/vernesong/OpenClash/blob/e553e82e01c697aefbe1555261a503f425e00ccd/luci-app-openclash/luasrc/model/cbi/openclash/servers.lua#L73-L98)，[编辑页可改订阅 URL](https://github.com/vernesong/OpenClash/blob/e553e82e01c697aefbe1555261a503f425e00ccd/luci-app-openclash/luasrc/model/cbi/openclash/proxy-providers-config.lua#L57-L88) | 开关保存在 OpenWrt 的 UCI。生成配置时跳过停用项的[提供商定义](https://github.com/vernesong/OpenClash/blob/e553e82e01c697aefbe1555261a503f425e00ccd/luci-app-openclash/root/usr/share/openclash/uci.rb#L763-L800)与[组引用](https://github.com/vernesong/OpenClash/blob/e553e82e01c697aefbe1555261a503f425e00ccd/luci-app-openclash/root/usr/share/openclash/uci.rb#L404-L413)。停用会让相关节点退出可选范围。 |
| Clash Party v2.0.5 | [本地配置编辑模式下的代理集合页](https://github.com/mihomo-party-org/clash-party/blob/v2.0.5/src/renderer/src/components/resources/proxy-provider.tsx#L157-L193)可添加、[编辑链接并保存或发布](https://github.com/mihomo-party-org/clash-party/blob/v2.0.5/src/renderer/src/components/local/provider-modal.tsx#L165-L212) | 所查代理集合页面未见同等的可恢复启停开关；本地模式由[草稿或发布状态生成 YAML](https://github.com/mihomo-party-org/clash-party/blob/v2.0.5/src/main/local/store.ts#L144-L169)。 |
| Clash Verge Rev v2.5.10 | [提供商弹窗](https://github.com/clash-verge-rev/clash-verge-rev/blob/v2.5.10/src/components/proxy/provider-button.tsx#L48-L119)提供查看及单项或全部刷新 | 所查入口未见提供商级增删、改链接或启停。整份配置订阅和原文编辑另有入口。 |

ClashBar 可以借鉴 OpenClash 的停用效果和 Clash Party 的桌面表单。按方案 A，停用信息保存在原 YAML 注释里，生效定义与组引用随之更新，配置仍可交给独立的 mihomo 运行。上述先例只说明管理方式，不能据此推断当前核心重载时的连接表现。

## 本地代码

- ProxyProvidersAndGroupsView 提供商行只有摘要与刷新；ProxyTabView 在没有运行态提供商时隐藏整个区域。
- ProviderDetail 仅为 API 解码模型，不含原生 URL、路径及停用来源。
- AppViewModel+Providers 的 mergedProviderDetailPreservingNodes 在 incoming 空节点时保留旧节点；需要区分有效空结果、接口失败和版本变化。
- AppViewModel+Polling 的 applyProxyGroupsResponse 在传入提供商字典为空时使用旧字典；禁用后可能留下节点延迟和类型缓存。
- QuickRuleService 已有候选、快照、备份、原子替换和恢复基础；commitRoutingRuleEdit 的运行对应检查是规则专用，提供商需要自己的快照与基线。
- 配置目录监控对未确认的自身写入会触发重启，需要沿用并扩展监控基线确认。

CodeGraph 已同步：explore updateProxyProvider 与 impact applyProxyGroupsResponse --depth 2。影响覆盖提供商行、刷新、代理组轮询、节点切换和连接 / 代理组详情；现有单项提供商更新入口未查到直接自动化测试。

## 配置结构核对

对上一会话使用的 default_limit_manual.yaml 只输出名称、类型和组引用结构：3 个 HTTP 提供商 fm / pq / cx，35 个组，17 个 include-all 组，无显式 use，16 个组带 filter 或 exclude-filter。没有输出订阅 URL 或授权信息。

因此推荐原生可恢复停用：移出有效提供商定义，同时保留可读注释。它自然覆盖当前自动引入结构；仅面板隐藏作为不同语义的候选保留供讨论。

## 原定验证范围

- 当前核心在禁用目标、保留其他提供商、再次启用和改链接四种情况下对真实提供商 TCP / UDP 连接的影响。
- 注释块在特殊 YAML、外部编辑和整份订阅覆盖后的保留 / 恢复边界。
- 各地区过滤组、无有效提供商、同名节点及 Global / Rule 模式的候选变化。
- 新 URL 加载失败、已有 cache 命中和核心返回成功但初始化失败的恢复。

## 实测结果

Mihomo v1.19.31 的独立测试覆盖停止核心时新增、启停与删除、显式和自动引用、节点过滤、改链、禁用后刷新返回 404、订阅预检失败，以及预检通过但运行态加载失败后回滚文件与核心配置。已有 TCP 连接经本地 SOCKS 节点建立，并通过 `providerChains` 分别确认归属 A 与 B；停用 A 后，A 的既有 TCP 在测试窗口内继续传输，仍有效的 B 的既有 TCP 中断。核心 PID 未变，混合端口、IPv6 与进程识别模式保持。未据此承诺其他连接持续，也未测试经提供商的 UDP。

本地测试覆盖 CRLF、流式配置、锚点、合并、停用恢复顺序、外部编辑、空组与成功空响应。真实核心与界面渲染均使用测试配置。未调整正在使用的 App 或核心。
