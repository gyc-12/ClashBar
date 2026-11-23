## ADDED Requirements

### Requirement: Native SVG support
The app SHALL 支持现有栅格图像以及原生可绘制的静态 SVG，SVG 按比例转换为透明 PNG 后缓存。

#### Scenario: SVG icon
- **WHEN** 成功下载 SVG 图标
- **THEN** 图标可显示，内存和磁盘保存可解码 PNG，无需修改图标 URL

#### Scenario: Existing PNG
- **WHEN** 图片是有效 PNG
- **THEN** 保持原有加载和缓存行为

### Requirement: Bounded validated caching
The app SHALL 限制下载大小、拒绝非图像或不成功的响应，不缓存失败，并复用同 URL 的在途请求。

#### Scenario: Failed download
- **WHEN** 网络错误或服务器返回非图像
- **THEN** 不缓存错误内容，下次请求可恢复

#### Scenario: Cached SVG conversion
- **WHEN** 同 URL 已有转换后的磁盘缓存
- **THEN** 可以离线读取，不再次请求网络或解析 SVG

### Requirement: Visible fallback and cancellation
The app SHALL 在加载失败时显示默认图标和说明，短暂失败有限重试，并隔离已取消任务。

#### Scenario: URL changes
- **WHEN** 图片加载期间 URL 改变
- **THEN** 旧 URL 的结果不覆盖新 URL 图像

#### Scenario: Unsupported content
- **WHEN** SVG 包含外部资源或无法渲染
- **THEN** 显示默认图标，不执行脚本或加载外部依赖
