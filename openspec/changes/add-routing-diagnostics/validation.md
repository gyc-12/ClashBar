## Validation

日期：2026-11-22。用户确认实现调研候选 1、2、3；本变更没有包含备份历史、应用流量汇总或 DNS 查询工具。

- `swift build` Debug 编译通过。
- `CLASHBAR_TEST_MIHOMO='/Users/gyc/Library/Application Support/clashbar/core/mihomo' CLASHBAR_TEST_RENDER_DIR=/tmp/clashbar-diagnostics-preview-final swift test`：52 个测试、11 个套件通过，包含原有规则写入、冲突、核心重载及图标回归。
- 新增 7 项模型/状态验证及 1 项渲染验证：真实时间不随轮询改变、同值新测量、无时间降级、手动与 API 历史合并、provider 时间、UInt64 统计、端口/进程解码、重复候选、本地/运行态绑定、仅在 sheet 关闭后进入编辑器、远程只读及目标切换清理。
- 新增真实核心集成验证：临时目录与独立 mihomo v1.19.31 进程，三个临时 loopback 端口及 Python HTTP/SOCKS 请求夹具。检测使用 HTTP HEAD；读取实际延迟时间、命中次数/时间、连接源/目标端口和代理链，PID 不变，测试配置原文不变。未使用正在运行的核心。
- 渲染检查包含诊断界面中英文、浅色/深色共 16 张，以及原有编辑器预览；检查代理组行的延迟年龄、详情宽度、连接滚动区域和规则统计列。
- `make spec-check`：5 个变更全部通过严格校验。
- `make graph` 同步 23 个文件；查询 `latencySamples` 和 `connectionRuleCandidates` 的 impact，检查代理行、详情、数据合并、跳转及测试调用关系。`.codegraph/` 未加入 Git。
- `make build WITH_CORE=0 APP_VERSION=0.1.0 BUILD_NUMBER=2` Release 编译及打包通过，输出 `dist/ClashBar.app`。
- `codesign --verify --deep --strict --verbose=2 dist/ClashBar.app` 通过；图标文件 42060 字节，中英诊断字符串均存在于资源包，`ClashBarBundlesMihomoCore=false`。
- `git diff --check` 通过。保留原有未提交修改，没有提交或推送。

## Behavior and limits

- 延迟历史保留最近 4 条。缺失测量时间显示未知；仅数据读取不会产生新测量时间。
- 已知间隔时超过两倍间隔（最低 60 秒）、未知间隔时超过 10 分钟显示较旧；这是展示提示，不是准确的调度倒计时。
- 核心未提供分组 URL 时，界面明确标注 App 默认探测地址；远程 interval/lazy 未提供时显示未知。
- 本地统计只在原生文件与当前核心完整对应时关联；规则重载后可能重置。计数与流量、丢包不同。
- 连接离开最多 120 行的保留列表时继续显示打开时快照，不声称构成完整关闭连接历史。
- 规则刷新默认读取数据，右键仍可选择更新所有规则集。自动分组重新测速会按 mihomo 原生行为清除手动固定选择；界面已说明。
- 只读诊断没有配置写入或核心重启。规则保存及组切换保持原有行为，连接路径与代理组现在的选择分别呈现。

## References

- [Zashboard 延迟时间](https://github.com/Zephyruso/zashboard/blob/b51d07099e0b18c0c5126cac22ed4e5e01291a1e/src/components/proxies/LatencyTag.vue)
- [Zashboard 命中统计](https://github.com/Zephyruso/zashboard/blob/b51d07099e0b18c0c5126cac22ed4e5e01291a1e/src/composables/use-rule-hit-tooltip.ts)
- [Zashboard 连接详情](https://github.com/Zephyruso/zashboard/blob/b51d07099e0b18c0c5126cac22ed4e5e01291a1e/src/components/connections/ConnectionDetails.vue)
- [mihomo 分组测速与固定选择](https://github.com/MetaCubeX/mihomo/blob/v1.19.31/hub/route/groups.go)
