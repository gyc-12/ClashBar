## Why

用户希望在分流页逐条编辑规则、明确查看自定义规则，并直接选择新的匹配策略或代理组。现有页面仅读取核心运行态的 type/payload/proxy，右键只支持从少数目标新增规则，不能可靠地定位并修改原来的规则行，也无法识别用户新增项。

## What Changes

用户已确认方案 A，按原生规则原位编辑实施；普通保存使用核心进程内重载。

- 分流页关联当前主配置原生 rules 与核心运行态，显示原始顺序、来源及应用状态。
- 每条主配置规则提供编辑入口；常见类型使用表单，复杂表达式保留原文编辑入口。
- 策略列提供可搜索选择器，选择代理组或内置策略后原位替换策略字段。
- 新增自定义规则筛选和来源标记，推荐用 YAML 注释标记用户规则，规则内容仍保存于原生 rules。
- 旧规则仍可编辑，并允许明确标记为自定义；不根据规则位置猜测来源。
- 复用候选校验、备份、原子写入、应用及失败恢复，保持其他规则顺序和运行设置。

## Capabilities

### New Capabilities
- `routing-rule-editor`: 原生规则来源映射、逐条编辑、自定义规则显示及策略选择。

### Modified Capabilities

无。已有快捷新增规则接入新编辑能力，新增置顶的语义保持。

## Impact

RulesTabView、RulesViewModel、规则展示模型、QuickRuleService、QuickRuleEditorView、AppViewModel 的规则与配置监控链路、中英文文案及测试。详细候选与计划见 design.md 和 research.md。
