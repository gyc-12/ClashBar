## Context

当前 imageData 下载后用 CGImageSourceCreateWithData 检查，失败即返回 nil。真实 Globe.svg 能通过 NSImage 解码，但 ImageIO 失败。图片没有进入缓存，界面只留下空白。

## Goals / Non-Goals

Goals：兼容用户现有 PNG/SVG 链接、保持缓存策略、有限网络重试、固定渲染尺寸、防止过期请求覆盖。

Non-Goals：改写用户配置、切换 CDN、改变网络/分流、引入 WebView 或第三方 SVG 库。

## Decisions

1. 先验证现有 ImageIO 支持的栅格数据；否则校验 SVG XML，再在 MainActor 使用 NSImage 绘制到 64×64 透明 sRGB 位图，保留比例并输出 PNG。
2. SVG 采用静态自包含内容，不加载外部资源或实体。常见 SVG 1.1 DOCTYPE 保留兼容性，但不解析外部 DTD；拒绝主动内容及非本地引用。
3. 原 2 MiB 下载上限、请求合并、128 项/20 MiB 磁盘预算保持；只缓存可绘制的图像，错误响应不进入缓存。后续启动只需读取 PNG。
4. 图标默认显示占位；短暂失败仅重试一次；旧 URL 的已取消任务不能修改当前图像。
5. 诊断不记录完整图标 URL，以免查询参数包含凭据。失败通过图标提示呈现。

## Risks / Trade-offs

AppKit 对复杂 SVG 特性的支持依系统版本变化，目标图标需要实际栅格化验证，不能只以 NSImage 创建成功为准。64×64 PNG 足够面板小图标和 Retina 显示；超出原生解码能力的文件保留失败占位。图片缓存属于可删除的显示数据，核心配置与运行态不涉及改动。

## Validation

独立构造的 SVG 测颜色/透明度/比例与非法输入；URLProtocol 验证网络、内存/磁盘命中、请求合并、失败后重试；对用户图标只下载到临时目录并用正式转换路径验证。swift test、Release 打包、OpenSpec strict 校验及 CodeGraph 同步。
