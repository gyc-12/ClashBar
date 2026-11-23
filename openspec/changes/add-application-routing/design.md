## Context

ClashBar 是 macOS 原生 mihomo 管理面板。现有规则保存支持冲突检查、备份和 PUT /configs 重载；连接元数据已有 process / processPath。

## Goals / Non-Goals

Goals：通过应用或当前进程创建精确原生规则，搜索策略，支持停止核心时保存；有效处理 find-process-mode，复用既有事务。

Non-Goals：Android VPN 应用排除、自动启用 TUN、将未进入核心的流量强制接管、自动为所有 Helper 生成规则、正则批量规则、远程文件写入、关闭现有连接、私有规则数据库或启动合并。

## Decisions

1. 在 /Applications、~/Applications、/System/Applications 中有界扫描 .app，跳过包内部，在后台读取 Bundle 的主 executableURL；支持原生文件选择器选择 .app。列表仅在用户打开编辑器时读取，不后台常驻扫描。
2. 最近进程来自当前已保留的连接快照，按可执行路径 / 名称去重。未知进程不从域名或应用展示名推断。单独标识其为已观测记录，不承诺完整系统进程列表。
3. 默认使用精确绝对路径；没有路径时使用进程名。手动输入保持大小写和内部空格，不解释为 URL / 域名；拒绝控制字符、逗号和无法安全预览的规则分隔符。应用 Helper 可从连接另行添加。
4. 扩展 QuickRoutingRule 支持两种进程条件，原有域名快捷编辑器仍只展示原有类型；domain / ipcidr provider 不接受进程条件。
5. 应用编辑器仅写主配置 rules。同类型、同条件的直接规则替换策略并置顶，其他规则顺序不变，沿用 clashbar:custom 注释；持久化数据完全为原生 YAML。
6. 从本地配置及可读取的当前运行态展示 find-process-mode。off 时默认勾选明确可见的“启用进程识别 strict”，取消后阻止无效应用。启用时将 strict 同时保存到原生文件和运行态；其余端口、TUN、模式保持原有运行值。若保存前运行态变为 off 且用户未选择启用，拒绝应用并提示重新确认。
7. 事务应用仅对明确选择修改的 find-process-mode 使用文件值，其他编辑继续保持原行为。回滚 payload 使用原运行态，失败时恢复原生文件与原运行设置。
8. 连接详情在自身 sheet 内展示应用编辑器，避免多层根 sheet 争用；右键从根入口打开。远程机器显示仅支持本地文件编辑说明。

## Risks / Trade-offs

- 精确主可执行文件不包含所有 Helper；路径升级或迁移后可能改变。进程名可能匹配其他同名程序，编辑器分别说明范围。
- 进程识别依赖核心能力与流量进入方式，不自动开启 TUN；Global / Direct 模式明确提示需 Rule 模式。
- 整份订阅更新会覆盖原生 rules 和进程识别设置；不隐式重合并，推荐稳定主配置与 proxy-providers。
- 不重启进程、不主动关闭连接。新规则作用于后续连接，重载窗口仍由核心决定。

## Validation

覆盖应用 Bundle 读取、路径 / 名称校验、去重和来源筛选、原生置顶和精确替换、off 到 strict、运行态保留及回滚、并发修改和本地限制。中英文浅深色渲染；独立临时 mihomo 验证进程规则匹配、PID 和既有 TCP 连续性。执行 swift build、swift test、make spec-check、CodeGraph 和无核心打包。
