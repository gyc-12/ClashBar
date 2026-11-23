## Research

调研日期：2026-11-22。阅读 GitHub 源码并固定提交，未安装或运行这些客户端；默认分支能力不代表对应稳定发行版已包含该功能。

### Clash Party

- 默认分支 smart_core，提交 `937bb7f4caef37baa4479faa6b14c26bf4a23235`。
- [规则页](https://github.com/mihomo-party-org/clash-party/blob/937bb7f4caef37baa4479faa6b14c26bf4a23235/src/renderer/src/pages/rules.tsx)：编辑模式读取本地原始规则及索引，查看模式读取核心运行态；筛选后的编辑仍使用原列表索引。
- [编辑器](https://github.com/mihomo-party-org/clash-party/blob/937bb7f4caef37baa4479faa6b14c26bf4a23235/src/renderer/src/components/rules/rule-editor-modal.tsx)：类型、目标、策略、附加参数；RULE-SET 使用规则集选择器，SUB-RULE 使用子规则目标；保存时替换指定索引。
- [规则解析](https://github.com/mihomo-party-org/clash-party/blob/937bb7f4caef37baa4479faa6b14c26bf4a23235/src/shared/local-rules.ts)：只拆分括号外的逗号，避免破坏 AND/OR/NOT 表达式。
- [写入](https://github.com/mihomo-party-org/clash-party/blob/937bb7f4caef37baa4479faa6b14c26bf4a23235/src/main/local/rules.ts)：比较 expected 列表检测并发修改，再对精确索引进行新增、替换、删除或排序。
- 适合参考逐条编辑、稳定索引和冲突检测。其本地模块/编译体系不直接移植到本项目。

### Clash Verge Rev

- 默认分支 dev，提交 `9c34864777259e143a9c90160f6cad6ea47fbfc1`。
- [规则编辑器](https://github.com/clash-verge-rev/clash-verge-rev/blob/9c34864777259e143a9c90160f6cad6ea47fbfc1/src/components/profile/rules-editor-viewer.tsx)：丰富类型、可搜索策略、RULE-SET 选择、no-resolve、原文模式及 prepend/original/append 分区。
- [规则行](https://github.com/clash-verge-rev/clash-verge-rev/blob/9c34864777259e143a9c90160f6cad6ea47fbfc1/src/components/profile/rule-item.tsx)：用类型标记区分新增、原始和删除项；检查的这个组件没有逐条编辑回调。
- 实际保存为 prepend/append/delete 的扩展配置，由客户端处理。适合参考来源分区与表单，不采用其覆写存储方式。

### Zashboard

- 默认分支 main，提交 `b51d07099e0b18c0c5126cac22ed4e5e01291a1e`。
- [规则表](https://github.com/Zephyruso/zashboard/blob/b51d07099e0b18c0c5126cac22ed4e5e01291a1e/src/components/rules/RulesTable.vue)：点击规则打开代理链及代理组面板，可以查看当前节点和延迟。
- 这条交互改变的是策略组的选择，不是主配置中单条规则的策略字段。适合参考策略链查看，但不能把它当作单条规则编辑方案。

### MetaCubeXD

- 默认分支 main，提交 `7d87587a411aca5bfe43852be02969bda0335870`。
- [规则页](https://github.com/MetaCubeX/metacubexd/blob/7d87587a411aca5bfe43852be02969bda0335870/packages/ui/pages/rules.vue)：规则编辑入口、整列表编辑及排序，保存后刷新运行态。
- [规则会话](https://github.com/MetaCubeX/metacubexd/blob/7d87587a411aca5bfe43852be02969bda0335870/packages/ui/composables/useRuleEditor.ts)：dirty/saving/conflict 状态和逐项 update。
- [配置会话](https://github.com/MetaCubeX/metacubexd/blob/7d87587a411aca5bfe43852be02969bda0335870/packages/ui/composables/useActiveProfileEditor.ts)：依赖 visual-config-editor 控制服务能力；仅有 mihomo API 的托管网页不显示编辑入口。
- 适合参考状态管理与冲突提示，不将控制服务作为 ClashBar 新依赖。

## Core and local findings

- [mihomo v1.19.31 规则 API](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/route/rules.go) 返回 index/type/payload/proxy 等字段，提供运行态禁用入口，没有持久化单条规则策略替换接口。
- [配置 API](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/route/configs.go) 的 PUT /configs 接受完整配置 payload/path。因此需要先保存原生文件，再沿已有事务链路应用。
- 本项目 RuleItem 没有保留 API index、原文或源文件位置；RulesViewModel 的筛选和按策略分组不能作为文件写入位置。
- 当前 QuickRuleService 新增主规则时置顶，并移除相同类型及目标的旧项，不能直接复用该操作来编辑已有行，否则会改变优先级和重复规则。
- 当前序列写入会重新序列化目标列表，不保留列表内注释；推荐方案使用注释识别自定义项，因此必须同时改进原文定位及注释保留。
- 用户示例配置有 56 条主规则：DOMAIN-SUFFIX 16、DOMAIN 1、DST-PORT 2、RULE-SET 36、MATCH 1。36 个规则集均为 HTTP 来源，34 个为 MRS；本次不改写它们的下载缓存。
- 本次已执行 make graph，并检查 saveQuickRule 与 updateVisibleRules 的影响关系。
