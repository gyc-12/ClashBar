## ADDED Requirements

### Requirement: Native group editing
面板 SHALL 支持添加、移除和重排已有节点或子组、删除无引用组，并拒绝循环、无有效来源及被引用的删除。

#### Scenario: Add a nested group
- **WHEN** 用户向 proxy 添加 us
- **THEN** 保存组名引用，保留顺序与订阅，不复制动态节点

#### Scenario: Reorder members and clear explicit proxies
- **WHEN** 用户调整策略组成员顺序，或移除带有订阅来源组中的全部显式成员
- **THEN** 原生配置按新顺序写回，并在无显式成员时移除空的 `proxies` 字段而不影响 `use`

### Requirement: Recoverable timeout folding
列表 SHALL 默认折叠连续三次独立超时的非选中叶节点，可展开、测速、选择，测速恢复即返回正常区。

#### Scenario: Selected node times out
- **WHEN** 当前选择持续超时或节点样本不足
- **THEN** 节点仍在主列表且不自动切换

### Requirement: Site reachability
面板 SHALL 区分 Gemini 与 ChatGPT 匿名网页的地区可用性与 ChatGPT、YouTube 的按组网络连通性，并准确标明实际检测路径。

#### Scenario: Gemini returns a regional refusal with HTTP 200
- **WHEN** Gemini 返回明确的不支持地区提示，即使页面成功加载
- **THEN** 显示地区受限；登录、验证、不可识别页面及只有延迟的响应不能显示地区支持

#### Scenario: Gemini returns modern JSON feature flags on a supported region
- **WHEN** Gemini 返回有效三字母地区码且以对象格式 `"45631641":true` 或数组格式 `45631641,null,true` 标明开放
- **THEN** 显示对应地区支持信号，不误判为无法确认

#### Scenario: Only a remote controller is accessible
- **WHEN** 不能通过该核心的代理端口读取实际页面
- **THEN** 不改用本机直连或用按组测速替代地区结论，不影响其余站点测速

#### Scenario: One site fails
- **WHEN** 一站点失败而其他站点可达
- **THEN** 分站点展示结果，不改变当前代理选择，且按组测速要求 2xx/3xx 响应

### Requirement: Configurable native subscriptions
面板 SHALL 支持新增及编辑 HTTP 订阅的名称、链接、更新间隔（含零）、健康检查开关及地址和间隔、下载策略、User-Agent 列表和节点前缀，默认使用通用配置（更新间隔 3600 秒、不预设特定前缀）并自动分配路径。

#### Scenario: Rename and edit an existing HTTP subscription
- **WHEN** 用户修改已有订阅的名称及其他原生参数并保存
- **THEN** 校验名称唯一性与保留字，同步更新 `proxy-providers`、`proxy-groups[].use` 与禁用元数据中的引用，保留未修改字段及未变更链接的缓存路径

#### Scenario: Direct fetch fails
- **WHEN** 新增源直连加载失败且存在可用的主代理策略组
- **THEN** 用该组重试一次，仅在候选验证成功后提交配置；两次失败不写原文件
