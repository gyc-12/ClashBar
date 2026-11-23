# 验证记录

2026-11-13，macOS 27.0、Apple Silicon。

- `swift build` 通过。
- 图标测试 8 项通过，包含 13 组无效输入、透明度/比例/纯色、本地渐变引用、请求合并、PNG 原样保留、磁盘缓存离线复用，以及失败/损坏缓存后恢复。
- 完整 `swift test` 通过，报告 25 个测试；启用独立 mihomo 核心集成和真实图标测试，跳过与本次改动无关的快捷规则编辑器预览导出。
- 用户配置的 29 个策略组对应 27 个不同图标：20 个 SVG、7 个 PNG。全部通过正式解码器，并人工查看生成的预览。下载内容仅保存在临时目录，现有 PNG 取自缓存副本。
- `make graph` 同步完成，`impact ProxyGroupIconDecoder --depth 2` 核对调用方集中在图标缓存及测试。
- `make spec-check` 严格校验 2 个变更通过。
- Release 无核心包生成于 `dist/ClashBar.app`，约 3.3 MiB；签名和 Info.plist 校验通过。使用 `swift build --build-system native -c release -Xswiftc -Osize` 生成打包脚本所需的传统产物路径，再运行打包脚本。
- `git diff --check` 通过。可视预览为 `dist/proxy-icons-preview.png`。

未操作运行中的核心、配置或 App。其他 macOS 版本的原生 SVG 支持尚未实机验证；复杂或非自包含 SVG 使用失败占位。构建的既有告警：仓库缺少预处理的 App 图标，测试包使用系统默认应用图标；当前 Swift 工具链提示 native 构建模式将废弃。
