## Why

本地无核心 App 缺少 `.icns` 和 `CFBundleIconFile`，Finder 显示通用图标。图标源文件存在，但跳过预处理直接打包时，脚本仅警告后继续生成缺图标的 App。

## What Changes

- 图标预处理缺少源文件或转换失败时返回失败。
- 打包前要求已生成非空图标，缺失时提示运行完整构建流程。
- 使用完整无核心构建流程重新生成 App，并核对图标资源、声明和签名。

## Capabilities

### New Capabilities
- `app-packaging`: 应用包必须包含图标资源及对应声明。

### Modified Capabilities

无。

## Impact

仅修改本地及 CI 共用的预处理和打包脚本，不涉及核心运行、用户配置或应用界面文案。
