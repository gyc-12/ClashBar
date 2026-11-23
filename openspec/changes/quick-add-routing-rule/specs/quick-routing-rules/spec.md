## ADDED Requirements

### Requirement: Browser target capture
The app SHALL 在用户点击时读取受支持前台浏览器的 HTTP(S) 标签页并预填规范化目标。

#### Scenario: Browser URL is available
- **WHEN** Safari 或受支持 Chromium 浏览器有网页标签页
- **THEN** 编辑器预填主机名，忽略端口、路径、查询和片段

#### Scenario: Capture fails
- **WHEN** 自动化权限拒绝、浏览器不支持或页面不是 HTTP(S)
- **THEN** 显示原因并允许手工输入，不创建规则

### Requirement: Contextual destinations
The app SHALL 从分流、连接、日志右键提供明确目标，并保留来源语义。

#### Scenario: Connection has domain and IP
- **WHEN** 连接同时包含域名与目标 IP
- **THEN** 分别提供选择，单个 IPv4 默认 /32，IPv6 默认 /128

#### Scenario: Unsupported source
- **WHEN** 规则是 RULE-SET、GEOIP、MATCH 或日志没有明确目标
- **THEN** 不把名称、源地址或普通文字推断为域名

### Requirement: Preview and scope
The app SHALL 支持 DOMAIN、DOMAIN-SUFFIX、IP-CIDR、IP-CIDR6，展示写入预览并拒绝非法目标和策略。

#### Scenario: Suffix selected
- **WHEN** 用户选择域名后缀
- **THEN** 只匹配确认的完整后缀，不自动扩大至注册域

### Requirement: Native configuration persistence
The app SHALL 默认直接修改主配置原生 rules，保存结果能由裸 mihomo 使用。

#### Scenario: Add native rule
- **WHEN** 保存到当前配置
- **THEN** 新规则置顶，相同类型与目标的旧项被替换，其余规则保持顺序

#### Scenario: Subscription file
- **WHEN** 编辑的主配置来自整份订阅
- **THEN** 提示更新可能覆盖规则或集合引用，不进行隐式重新合并

### Requirement: Existing local providers
The app SHALL 允许追加到已有、可写、工作目录内且被引用的 file 规则集，支持 yaml/text 和对应 behavior。

#### Scenario: Append to a provider
- **WHEN** 用户选择一个本地规则集
- **THEN** 策略来自现有 RULE-SET，追加兼容条件并去重，不修改主配置或创建集合

#### Scenario: Unsupported provider
- **WHEN** 集合是远程 HTTP、MRS、不可写、未引用或路径不在工作目录内
- **THEN** 不提供写入入口

### Requirement: Validated transactional save
The app SHALL 校验候选、备份原文、原子写入并应用，失败恢复并明确反馈。

#### Scenario: Validation fails
- **WHEN** mihomo 拒绝候选配置
- **THEN** 原文件不变，不显示成功

#### Scenario: Reload fails
- **WHEN** 核心应用失败
- **THEN** 恢复旧文件并尝试恢复运行状态，恢复失败时显示备份位置

#### Scenario: Concurrent modification
- **WHEN** 校验期间或恢复前检测到外部修改
- **THEN** 不覆盖外部内容，提示重新打开编辑器或使用备份恢复

#### Scenario: Remote machine
- **WHEN** 管理远程机器
- **THEN** 禁用本地快捷编辑并说明限制
