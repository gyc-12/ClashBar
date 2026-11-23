## Context

ClashBar 使用 Swift 6 / SwiftUI / AppKit 和 mihomo REST API，主配置位于 config 目录，目录监控会触发重启。原规则页面只读。产品保持“裸核心 + 管理面板”，不以 App 私有规则作为数据来源。

GitHub 调研（2026-11-13）：
- [Clash Verge Rev rules-editor-viewer.tsx](https://github.com/clash-verge-rev/clash-verge-rev/blob/dev/src/components/profile/rules-editor-viewer.tsx)：参考类型、条件、策略、no-resolve 和去重交互。
- [Clash Party connection-detail-modal.tsx](https://github.com/mihomo-party-org/clash-party/blob/main/src/renderer/src/components/connections/connection-detail-modal.tsx)：参考结构化 host/destinationIP 来源，本次查看的组件未发现直接添加功能。
- [mihomo 原生 rule-provider 文档](https://wiki.metacubex.one/config/rule-providers/)：file/domain/ipcidr/classical、yaml/text 格式。
- [mihomo provider route](https://github.com/MetaCubeX/mihomo/blob/Meta/hub/route/provider.go)：PUT /providers/rules/{name} 刷新已有文件。

## Goals / Non-Goals

Goals：一次编辑流程服务各入口；保存即为原生文件；可命令行运行；校验、备份、失败恢复；保留已有配置职责。

Non-Goals：私有规则数据库、启动时合并、整份订阅自动合并、本地规则集自动创建、远程服务器文件编辑、远程规则集缓存编辑、关闭现有连接、自动推断 eTLD+1。

## Decisions

1. 默认写主配置 rules 顶部，替换同类型、同规范化目标的旧项，其余范围和顺序不变。Yams 定位顶层字段；普通块格式只重新序列化目标列表，保留其他配置原文。编辑后核对整份文档语义；流式根映射、跨字段锚点等无法安全局部编辑的情况使用等价的完整 YAML 序列化。
2. 本地集合仅列出已有、可写、位于 mihomo 工作目录内且被顶层 RULE-SET 引用的 type:file / format:yaml 或 text 文件。不创建集合，不修改策略绑定。追加内容沿用集合 behavior 和 RULE-SET 顺序，重复条目不增加。
3. 保存前在同一工作目录的隐藏临时文件中构造候选配置，由 mihomo -t 验证；集合候选通过临时配置引用临时集合，避免提前暴露未校验内容。校验后检查原始文件快照，备份目标文件，原子替换并保留文件权限。
4. 主配置改动通过 PUT /configs 应用，payload 保留当前可编辑的运行设置；集合改动仅刷新对应 provider。payload 不持久化。已有启动、重启链路保持直接读取主配置。
5. 应用失败恢复旧文件并重新加载；若恢复失败或检测到外部修改，不覆盖外部内容，给出备份路径和错误。保存期间防止配置切换、远程切换及订阅写入，目录监控识别自身写入避免多余重启。
6. 浏览器只在点击时发 Apple Events；打开面板激活 App 前记住前台应用。使用固定应用白名单，不执行网页 JavaScript。拒绝内部页面，失败时允许手动输入。
7. 连接使用结构化 host/destinationIP；规则只接受 domain/domain-suffix/IP-CIDR 类型；日志解析箭头目标、dial、lookup 字段。域名后缀必须明确选择。

## Risks / Trade-offs

- 整份订阅更新会覆盖用户改动，甚至覆盖对仍存在的本地规则文件的引用；编辑器和使用文档明确提示。推荐稳定主配置 + proxy-providers 节点订阅。
- YAML 目标列表内的注释可能被重新序列化；修改前完整原文有备份。主配置其他块保留原样，特殊 YAML 仍须内核校验。
- 远程目标只有 API，没有通用文件写入能力，因此禁用并说明。
- Apple Events 授权由系统决定；Firefox 等浏览器手动输入。
- 规则作用于新连接，Global/Direct 模式提示切换 Rule；追加到集合不改变原有优先级。

## Validation

Swift Testing 覆盖目标解析、来源过滤、YAML 变体、主配置替换、provider 行为与格式、临时校验、备份、回滚、并发修改和运行设置。使用独立 mihomo 进程验证原生文件和 API，避免改动正在使用的核心。构建、打包用途声明、OpenSpec strict 校验与 CodeGraph 更新。
