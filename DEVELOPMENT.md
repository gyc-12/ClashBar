# 开发工作流

项目使用 OpenSpec 记录需求、设计和验证任务，使用 CodeGraph 查询 Swift 符号及调用关系。两个工具按固定版本通过 npx 运行，不要求全局安装。

```sh
make spec-check                 # 校验 OpenSpec
make graph                      # 首次索引或同步当前项目
npx --yes @colbymchenry/codegraph@1.6.2 explore saveQuickRule
npx --yes @colbymchenry/codegraph@1.6.2 impact writeConfigData --depth 2
swift test
```

`.codegraph/` 是本地索引，已忽略，不作为源代码提交。CLI 查询前运行 `make graph`，确保图与当前文件一致。MCP 接入可另行配置；本项目的构建不依赖 MCP 或 CodeGraph。

OpenSpec 的变更位于 `openspec/changes/`，项目约束位于 `openspec/config.yaml`。新功能先完善 proposal、design、specs 和 tasks，再实现与验证。当前快捷规则变更为 `quick-add-routing-rule`。

## 原生配置原则

ClashBar 是 mihomo 管理面板。规则保存到原生 `rules` 或已有 `type: file` 的规则集，同一配置可以脱离 ClashBar 运行。不添加私有规则数据库，也不在启动时做隐式合并。整份订阅覆盖更新的取舍须明确呈现给用户。

## 快捷规则验证

常规测试使用临时目录和注入的校验、应用闭包，覆盖 YAML 编辑、备份恢复、并发修改、来源解析和 provider 格式。

可选的真实核心测试使用独立工作目录、临时本地端口和无代理监听的配置，不操作正在使用的核心：

```sh
CLASHBAR_TEST_MIHOMO=/absolute/path/to/mihomo swift test
```

可选导出编辑器中英文、浅色和深色预览（不会启动核心）：

```sh
CLASHBAR_TEST_RENDER_DIR=/tmp/clashbar-preview swift test --filter renderEditorForVisualReview
```

浏览器真实读取需使用打包的 App 手工验证自动化授权，包括允许、拒绝、无标签页及非 HTTP(S) 页面。测试不替用户批准系统权限。

## 策略组图标验证

`swift test --filter ProxyGroupIcon` 覆盖 SVG 的透明度、比例、颜色与本地渐变引用，以及下载校验、请求合并、磁盘缓存和失败后恢复。

可选读取本地目录内的 SVG/PNG，通过正式解码器生成 `rendered/icons.png` 预览，便于核对实际图标。测试不会下载图片或写入运行中 App 的缓存：

```sh
CLASHBAR_TEST_ICON_DIR=/tmp/clashbar-icon-fixtures swift test --filter ProxyGroupIcon
```

## 原位规则编辑验证

`NativeRoutingRuleTests` 覆盖按原索引编辑重复项、复杂表达式、自定义注释、流式/锚点/合并 YAML、CRLF 和运行 TUN 设置；`NativeRuleViewModelTests` 验证核心停止时的展示、原生保存、监控基线及外部修改后的冲突恢复。

真实核心测试仍只启动临时目录中的独立进程。`NativeRuleReloadIntegrationTests` 使用 loopback 的 TCP/UDP 回显服务与独立 SOCKS 监听，验证 PID 不变、既有 TCP 连续传输、新连接策略、TUN/端口保持，并记录 UDP 超时数。它通过 `Scripts/probe_native_rule_reload.py` 驱动测试流量；不会发现或修改用户运行中的核心。

```sh
CLASHBAR_TEST_MIHOMO=/absolute/path/to/mihomo swift test
CLASHBAR_TEST_RENDER_DIR=/tmp/clashbar-native-preview swift test --filter renderNativeRulesForVisualReview
```

## 分流诊断验证

`RoutingDiagnosticsTests` 验证延迟时间合并和缺失字段、规则统计关联/排序、连接元数据及重复规则候选。渲染使用独立测试配置和 loopback 的无服务目标，避免访问正在使用的控制器。

`RoutingDiagnosticsIntegrationTests` 通过 `Scripts/probe_routing_diagnostics.py` 启动 loopback HTTP 服务与持久 SOCKS 连接，在独立核心上验证真实测量时间、规则命中和连接详情；不写入用户配置或访问正在使用的核心。

```sh
swift test --filter RoutingDiagnosticsTests
CLASHBAR_TEST_MIHOMO=/absolute/path/to/mihomo swift test --filter RoutingDiagnosticsIntegrationTests
CLASHBAR_TEST_RENDER_DIR=/tmp/clashbar-diagnostics-preview swift test --filter renderDiagnosticsForVisualReview
```

## 应用分流验证

`ApplicationRoutingTests` 和 `ApplicationRuleViewModelTests` 覆盖应用主可执行文件读取、已观测进程、精确条件校验、原生置顶与去重、进程识别设置、运行态保留、冲突及本地限制。

`ApplicationRoutingIntegrationTests` 复制测试核心到独立临时目录并取消特权位。通过 loopback SOCKS 和回显服务验证 PROCESS-NAME / PROCESS-PATH 匹配、off 到 strict、端口 / TUN 保持、PID 不变及既有 TCP 连续性。测试不访问用户控制器或修改用户配置。

本机 macOS 27 的无特权核心不能获取其他进程的连接信息，独立测试返回 `process not found`。可显式设置 `CLASHBAR_TEST_PROCESS_PRIVILEGES=1`，使用传入的、已具备所需权限的核心可执行文件；仍仅启动临时配置、独立端口和独立进程，不安装、改权限或操作已有核心。不能通过跳过匹配断言来把无进程识别能力视作测试成功。

```sh
swift test --filter 'ApplicationRoutingTests|ApplicationRuleViewModelTests'
CLASHBAR_TEST_MIHOMO=/absolute/path/to/mihomo swift test --filter ApplicationRoutingIntegrationTests
CLASHBAR_TEST_MIHOMO=/absolute/path/to/privileged/mihomo CLASHBAR_TEST_PROCESS_PRIVILEGES=1 swift test --filter ApplicationRoutingIntegrationTests
CLASHBAR_TEST_RENDER_DIR=/tmp/clashbar-app-routing-preview swift test --filter renderApplicationRoutingForVisualReview
```
