## Context

`build.sh app` 依次执行预处理和打包，`build.sh package` 只执行打包。后者在没有预处理图标时仍成功，导致产物缺图标。无核心标志只控制 mihomo，不应影响应用图标。

## Goals / Non-Goals

Goals：让图标成为成功打包的必要资源；缺失时在替换旧产物前报错；交付带现有品牌图标的无核心 App。

Non-Goals：重绘图标、改变核心打包策略、安装或启动用户正在使用的 App。

## Decisions

1. 继续以已有 `BrandLogo.imageset/logo.png` 为源，通过 `sips` 和 `iconutil` 生成图标。
2. 图标源缺失或转换失败时预处理返回非零状态，不再仅输出警告。
3. 打包在编译及移除已有 App 前检查预处理图标非空；缺失时提示通过 `make build` 运行完整流程。
4. 成功打包始终复制 `.icns` 并写入 `CFBundleIconFile`。原生配置文件、核心运行态和订阅更新不涉及任何变化。

## Validation

检查 Shell 语法与缺失图标的失败路径，执行 `swift build`、现有 Swift 测试、`make build WITH_CORE=0` 和 `make spec-check`。使用 `iconutil` 解码产物图标、核对 plist 和无核心标志，并验证 App 签名。
