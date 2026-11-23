## ADDED Requirements

### Requirement: Required application icon
打包流程 SHALL 在成功生成 App 时包含有效的应用图标资源和对应的 `CFBundleIconFile` 声明，不受是否内置核心影响。

#### Scenario: Build without core
- **WHEN** 使用 `make build WITH_CORE=0` 完成完整构建
- **THEN** App 包含品牌图标及图标声明，且不内置 mihomo

#### Scenario: Missing preprocessed icon
- **WHEN** 直接打包时预处理图标缺失或为空
- **THEN** 在替换已有 App 前失败并提示完整构建入口

#### Scenario: Icon preprocessing failure
- **WHEN** 图标源文件缺失或转换失败
- **THEN** 预处理返回失败，完整构建不会继续生成缺图标的 App
