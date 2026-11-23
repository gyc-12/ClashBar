## Why

浏览器访问异常或在分流、连接、日志中定位目标后，用户仍需手工编辑 YAML 才能指定策略。需要统一快捷入口，并保持“裸 mihomo 核心 + 管理面板”的产品定位，保存结果可以脱离 ClashBar 运行。

## What Changes

- 从 Safari / 受支持 Chromium 浏览器当前 HTTP(S) 标签页预填域名，失败可手动输入。
- 分流规则、连接和 mihomo 日志右键预填明确域名或目标 IP。
- 支持 DOMAIN、DOMAIN-SUFFIX、IP-CIDR、IP-CIDR6、策略选择和规则预览。
- 默认直接写原生 rules 顶部，相同类型与目标替换策略。
- 可追加到已有、可写且被主配置引用的本地 rule-provider；保持已有绑定和优先级。
- 校验候选文件、备份、原子写入、核心应用、失败恢复；检测并发编辑。
- 提示整份订阅更新可能覆盖规则或规则集引用，不承诺自动重新合并。

## Capabilities

### New Capabilities
- `quick-routing-rules`: 目标提取、规则编辑与原生文件持久化。

### Modified Capabilities

无现存 OpenSpec 能力。

## Impact

SwiftUI 菜单、AppViewModel、配置监控和写入冲突保护；Yams 依赖；Apple Events 用途声明；Swift Testing。启动和重启继续直接读取用户原生配置。
