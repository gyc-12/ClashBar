## ADDED Requirements

### Requirement: Consistent native typography and surfaces
The app SHALL 使用系统界面字体、专用技术等宽字体和统一内嵌卡片，在中文、英文及浅深色外观下保持清晰层级。

#### Scenario: Read interface labels and technical data
- **WHEN** 用户查看导航、组名称、端口、日志或规则表达式
- **THEN** 界面文字使用系统字体，技术内容使用等宽字体，数值保持对齐

#### Scenario: Hover or focus an icon action
- **WHEN** 用户将鼠标悬停或键盘聚焦到编辑笔、详情、测速、刷新或更多菜单等紧凑图标按钮上
- **THEN** 按钮提供完整方形点击热区与圆角变色悬停背景，图标同步高亮；禁用状态不显示误导性悬停高亮

#### Scenario: Reduce transparency
- **WHEN** 系统启用减少透明度
- **THEN** 卡片使用可读的实色背景，文字和选中状态仍清晰

### Requirement: Panel navigation and bounded layout
The app SHALL 使用 376pt 面板、紧凑水平模式切换和清晰页面选中状态，并把头部、导航和底部操作纳入屏幕高度限制。

#### Scenario: Switch to a long list
- **WHEN** 用户进入规则、连接或日志页并滚动
- **THEN** 内容在可用区域滚动，过滤工具保持置顶，导航和页脚仍可访问

#### Scenario: Short available screen
- **WHEN** 屏幕可用高度小于内容高度
- **THEN** 面板不超出最大高度，内容仍可滚动且底部操作可见；规则统计和来源可以滚出，置顶筛选区下仍能完整阅读规则行

#### Scenario: English page labels
- **WHEN** 用户使用英文界面
- **THEN** 页面导航按文字所需宽度布局，Connections 等标签完整显示，辅助功能名称保持一致

#### Scenario: Open the configuration switcher
- **WHEN** 用户打开「切换配置」
- **THEN** 配置列表、管理操作和 Wi-Fi 自动切换使用与主面板一致的卡片，当前文件有勾选标记；远程刷新、右键绑定和删除保持可用，长列表可滚动

### Requirement: Readable traffic dashboard
The app SHALL 在节点页默认以单行紧凑条呈现实时上下行速率、连接数与内存，并通过系统设置中的开关控制是否显示平滑流量曲线图。

#### Scenario: Traffic chart toggled off by default
- **WHEN** 用户首次打开节点页或未开启流量曲线图开关
- **THEN** 顶部只显示紧凑的单行速率与状态摘要，不渲染曲线图，为下方提供商和策略组保留首屏空间

#### Scenario: Traffic peaks
- **WHEN** 用户开启流量曲线图开关且历史包含尖峰、零值或持续相等值
- **THEN** 曲线不遮挡文字、不产生负流量或越界峰值，空历史和单点可以正常显示

### Requirement: Accessible proxy controls and latency disclosure
The app SHALL 在节点页以双列磁贴呈现系统代理与 TUN，在系统设置页提供切换配置与终端代理命令入口，保留原有操作边界，并按语义区分延迟与逐步显示次要操作。

#### Scenario: Hover or focus a group
- **WHEN** 用户悬停或通过键盘聚焦策略组操作
- **THEN** 显示测量时间和测速入口，辅助功能仍可访问测速，行布局不跳动

#### Scenario: Distinguish latency states
- **WHEN** 节点未测量、失败或返回不同延迟
- **THEN** 文字与颜色共同区分状态，绿为小于 150ms，琥珀为 150 至 350ms，珊瑚为超过 350ms

#### Scenario: Open a node menu
- **WHEN** 用户打开指定宽度的节点菜单
- **THEN** 内边距计入外部面板尺寸，选中状态、节点名和延迟胶囊位于可见区域内，超长内容可滚动

### Requirement: Consistent editors and diagnostics
The app SHALL 为编辑与诊断弹窗提供统一标题、滚动表单和固定操作栏，同时保留保存、失败恢复、备份与来源提示。

#### Scenario: Long form or save feedback
- **WHEN** 编辑器内容、错误或订阅提示超过可用区域
- **THEN** 内容可滚动，取消、保存或关闭操作仍可访问，保存中仍禁止意外关闭

### Requirement: Preserve native configuration behavior
The app SHALL 复用原有原生文件与运行态事务，界面优化不得引入私有持久化或隐式订阅合并。

#### Scenario: Save after UI optimization
- **WHEN** 用户通过更新后的界面保存规则或提供商
- **THEN** 结果仍直接写入 mihomo 原生配置，未应用状态和整份订阅覆盖提示准确保留
