## Why

用户配置混用 PNG 和 SVG。现有下载及缓存仅通过 ImageIO 校验，ImageIO 拒绝 SVG，导致 22 个 SVG 图标空白，而 7 个 PNG 正常。当前 macOS 的 AppKit 可以解码这些 SVG，需要修复应用加载链路。

## What Changes

- 保留现有栅格图片处理，增加 AppKit 原生 SVG 解码和固定尺寸 PNG 转换。
- SVG 转换后的 PNG 使用现有内存和磁盘缓存，无新增依赖。
- 加载及失败时显示默认图标，短暂失败有限重试，URL 变化时避免旧任务覆盖新状态。
- 添加解码、缓存、下载失败和真实 SVG 验证。

## Capabilities

### New Capabilities
- `proxy-group-icons`: HTTP(S) 图标下载、PNG/SVG 解码、缓存与占位。

### Modified Capabilities

无。

## Impact

ProxyGroupIconCache、ProxyGroupIconView、新图片解码器及测试。用户 YAML、规则、DNS 和 IPv6 设置不变。
