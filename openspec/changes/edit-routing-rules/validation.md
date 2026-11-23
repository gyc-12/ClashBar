## Validation results

2026-11-22 完成方案 A：主配置原生规则原位编辑。

- `swift build` 通过。
- `CLASHBAR_TEST_MIHOMO=... CLASHBAR_TEST_RENDER_DIR=... swift test`：43 个测试、9 个测试组通过。真实核心为 mihomo v1.19.31。
- `make spec-check`：四项 OpenSpec 变更严格校验通过。
- `make graph` 更新索引，检查 `saveNativeRule`、`commitRoutingRuleEdit` 和目录写入确认的调用与影响；`.codegraph/` 未提交。
- 中英文、浅色/深色的分流页和 RULE-SET 编辑器已导出并检查，表单与操作按钮没有遮挡，列表长文本按行宽截断；自定义来源、原始序号、策略入口和离线保存状态可见。可用 DEVELOPMENT.md 中的预览命令复现。
- `make build WITH_CORE=0` 生成 `dist/ClashBar.app`，体积约 3.5 MiB。Info.plist 中 `ClashBarBundlesMihomoCore=false`，包内不存在 mihomo/mihomo.gz。512px ICNS 图标有效，中英文编辑器资源齐全；`codesign --verify --deep --strict` 通过。

## Coverage

纯逻辑与文件测试覆盖主配置重复项按源索引准确编辑、策略附加参数、逻辑表达式、原注释、CRLF、流式/锚点/合并 YAML 等价性、自定义标记增删、旧快捷新增接入、筛选及分组身份、文件冲突、备份与失败回滚、运行模式/端口/完整 TUN 设置保持。

视图模型测试使用独立临时目录，验证停止核心时的规则展示和保存，以及外部编辑被拒绝后重新显示新文件内容。路径的符号链接别名视为同一配置文件。

独立真实核心测试验证 DOMAIN-SUFFIX、DST-PORT、RULE-SET、IP-CIDR、AND、SUB-RULE 和 MATCH 的编辑后配置校验；逻辑表达式按核心返回的格式核对运行态，SUB-RULE 对应 API 的 SubRules 类型。

真实保存入口测试使用临时安装目录中的独立 MihomoProcessManager 和配置目录监控器，经 AppViewModel.saveNativeRule 保存并等待监控事件后，核心 PID 保持原值，没有待处理的目录变更重启；仅改变自定义标记也保持原进程。

## Connection behavior

TCP/UDP 回显探针只使用独立测试核心和临时 loopback 端口。最终运行记录：既有 TCP 连接 68 次回显、0 个连接错误，重载期间及之后继续完成 62 次回显；新 TCP 连接被新 REJECT 策略拒绝。核心 PID 不变，实际 TUN 对象、端口及运行设置保持。

最终探针记录 UDP 144 次回显、0 次超时；此前验证运行记录过 1 次 UDP 超时。因此结果不构成所有协议无中断的保证。配置重载仍可能让新请求或 UDP 数据包在暂停窗口短暂失败。规则不会迁移或主动关闭已有连接。

测试未修改用户现用配置，未控制用户运行中的核心。产物保留原有 ClashBar 名称与应用标识，可继续使用本地安装的核心及原生配置目录。
