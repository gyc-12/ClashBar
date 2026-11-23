## Validation

- `bash -n Scripts/preprocess.sh Scripts/package_app.sh Scripts/build.sh` 通过。
- 临时目录验证图标缺失、空图标、源图片缺失及转换失败四种情况均返回非零状态；打包失败时已有 App 的 plist 哈希不变。
- `swift build`、`swift test` 通过；Swift Testing 报告 25 个测试，其中真实核心、编辑器预览和外部图标目录相关的三个可选测试跳过。
- `make build WITH_CORE=0` 成功，产物为 `dist/ClashBar.app`。
- plist 声明 `ClashBar.icns`，`iconutil` 能还原五个尺寸的 PNG；`NSWorkspace.shared.icon(forFile:)` 读取并渲染后确认是品牌猫咪图标。
- `ClashBarBundlesMihomoCore` 为 false，包内没有 `mihomo` 或 `mihomo.gz`。
- `codesign --verify --deep --strict --verbose=2` 通过。
- `make spec-check` 三项变更全部通过；`make graph` 已同步。CodeGraph 对 Shell 函数名查询返回宽泛匹配，实际构建链路以直接阅读 Makefile 和三个构建脚本核对。
