# 验证记录

日期：2026-11-13。

- Swift 6.4 构建成功，目标保持 macOS 13+。
- Swift Testing 共 17 个测试方法（含参数化测试、可选集成与预览测试）；完整启用真实核心与预览时通过。普通测试不依赖本机浏览器或核心。
- 独立 mihomo v1.19.31：候选配置校验、PUT /configs payload 应用、保持 Global 运行模式、规则列表核对、IP-CIDR6 本地 classical 集合追加、PUT /providers/rules 刷新和最终原生配置独立校验通过。
- 参数化案例覆盖 URL/IDN/IPv4/IPv6/CIDR、错误输入和 YAML 块/流式/CRLF/锚点/合并/文档结束标记。
- 校验失败不写入、API 失败恢复、并发编辑不覆盖、备份保留及临时文件清理通过。
- 编辑器简中/英文、浅色/深色离屏预览已查看。补充了 SwiftPM 测试环境的资源 bundle 查找，使测试能读取正式本地化资源。
- `swift build --build-system native -c release -Xswiftc -Osize` 和 `Scripts/package_app.sh` 打包通过。当前 Swift 6.4 默认构建目录与项目脚本的历史查找目录不同，因此先生成 native 输出供原打包脚本读取；未扩大本功能的打包脚本改动范围。
- `dist/ClashBar.app` 为本地签名、无核心测试包，约 3.3 MB；`codesign --verify --deep --strict`、Info.plist 和中英 strings 校验通过。仓库缺少原 logo.png，因此测试包没有预处理应用图标。
- `make spec-check` strict 校验通过；`make graph` 同步并查询 saveQuickRule / 配置写入影响。

待真实交互验收：首次浏览器 Apple Events 自动化授权的允许/拒绝弹窗，以及各浏览器当前标签页读取。自动化测试未替用户授予系统权限，也未启动或替换用户正在使用的 ClashBar / mihomo。
