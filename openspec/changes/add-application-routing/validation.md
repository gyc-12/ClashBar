# 应用分流验证记录

日期：2026-11-23；macOS 27 / Darwin 27，Apple Swift 6.4 工具链（Package tools 6.2）；测试核心 mihomo v1.19.31 darwin arm64。

## 常规验证

- `swift build` 通过。
- `swift test` 完整回归报告 62 项测试、14 个 suite 通过。真实核心测试使用独立进程、临时配置与独立 loopback 端口。
- `make spec-check`：6 个 OpenSpec 变更通过 strict 校验。
- 中英文 strings 通过 plutil 校验；`git diff --check` 通过；Python 探针语法通过。
- `make graph` 更新索引，`explore saveApplicationRule` 检查入口、保存和测试关联。

## 新功能覆盖

- 应用 Bundle 的展示名与实际主可执行文件分开读取，目录扫描去重、跳过包内 Helper。
- 从明确的 process / processPath 生成已观测候选；缺失字段不由域名猜测。
- 精确路径、进程名、大小写与内部空格，拒绝逗号、控制字符和非法路径。
- 块、流式、锚点、CRLF / 文档标记 YAML；相同类型与条件去重置顶，其他规则顺序与语义保持，自定义标记保留。
- unquoted `off` 在 Yams YAML 1.1 中会变成 false，读取时明确识别为 off，避免误认成默认 strict。
- 原生 strict 显式保存并覆盖相应运行设置；端口、模式、TUN 等其他值仍来自运行态，失败恢复旧文件与 off 设置。
- 停止核心时保存、外部修改冲突、忙碌和远程限制。

## 真实核心结果

本机无特权核心的进程识别返回 `process not found`，对应新连接未命中进程规则，匹配测试如实失败。随后通过显式 `CLASHBAR_TEST_PROCESS_PRIVILEGES=1` 使用已有的有权限核心可执行文件，仍只创建独立测试进程和临时配置，不安装、改权限或操作用户运行中的核心。

- PROCESS-NAME 与 PROCESS-PATH 均在 strict 开启后命中新连接，所选 REJECT 生效。
- 核心 PID 不变，mixed-port、IPv6、并发和完整 TUN 运行对象保持。
- 已建立 TCP 的 reload 后持续回显分别为 33、34 次，无 TCP 错误。
- 覆盖文件 off，以及文件 strict / 运行态 off 两种来源；未选择启用时保存被拒绝，文件不变。
- 最终文件通过独立裸核心 `-t` 校验，原生规则与运行态对应。
- 回归中的原生 TCP / UDP 探针同样通过，记录到一次 UDP 超时；不承诺配置重载对所有协议绝对无中断。

## 界面

导出并检查 zh-Hans / en 的浅色和深色编辑器。使用注入的临时配置和固定应用候选，无扫描或用户控制器访问。检查长路径、策略按钮、strict 状态、保存反馈和固定在底部的订阅覆盖提示。

预览目录：`/tmp/clashbar-app-routing-preview-20261123`。

## 交付

使用说明：`docs/content/docs/application-routing.mdx`；无核心包目标：`dist/ClashBar.app`，0.1.0 / build 3。

`make build BUILD_NUMBER=3 WITH_CORE=0` 通过，App 约 3.9 MiB。codesign deep / strict 验证通过，Info.plist 版本、非空 icns、双语应用分流文本与无核心 payload 均已核对。
