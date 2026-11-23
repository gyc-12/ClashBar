## ADDED Requirements

### Requirement: Native provider management
The app SHALL 从当前本地主配置读取有效及受管理禁用的原生提供商定义，并支持添加、永久删除和编辑 HTTP(S) 订阅链接。

#### Scenario: Add the first provider
- **WHEN** 当前本地配置没有提供商或核心停止
- **THEN** 面板仍显示添加入口，成功保存原生定义，并准确标明是否已应用

#### Scenario: Edit an existing source
- **WHEN** 用户更换 HTTP 提供商订阅链接
- **THEN** 保留其他未修改原生字段和禁用状态，校验新源，并确保旧缓存不能掩盖新源加载失败

### Requirement: Recoverable native suspension
The app SHALL 按已确认方案 A 将禁用定义及需要恢复的引用保存在同一配置的可读受管理注释中，并在用户启用时显式恢复原生有效配置。

#### Scenario: Disable a provider
- **WHEN** 用户禁用提供商并成功应用
- **THEN** 该提供商退出有效定义，其节点退出核心的新连接候选，管理卡片保留并展示已禁用

#### Scenario: Enable after external edits
- **WHEN** 恢复时名称冲突、原组已删除或受管理引用上下文不能可靠对应
- **THEN** 拒绝有歧义的恢复并显示冲突，不覆盖外部编辑

#### Scenario: Run without the app
- **WHEN** 使用保存后的配置直接运行裸 mihomo
- **THEN** 有效及禁用结果由该原生文件直接决定，不依赖启动合并或私有数据库

### Requirement: Native group dependency preservation
The app SHALL 正确协调 use、include-all、include-all-providers、include-all-proxies 及过滤条件，保留未涉及的组语义与成员顺序。

#### Scenario: Automatically included provider
- **WHEN** 自动引入提供商的组关联到被禁用或删除的项
- **THEN** 该项不再被自动引入，其他有效提供商按原生逻辑继续引入

#### Scenario: Missing members
- **WHEN** 操作导致组缺少有效来源或没有可用成员，且没有用户明确的有效回退选择
- **THEN** 展示受影响组并阻止无效应用，引导选择备用或回退策略

### Requirement: Consistent panel state
The app SHALL 区分原生编辑状态和核心运行摘要，保证晚到响应及旧节点缓存不会重新显示已禁用或删除的节点。

#### Scenario: Empty provider response
- **WHEN** 成功响应明确返回空节点或提供商已经被移除
- **THEN** 清理对应旧节点，不把该结果当作接口不可用

#### Scenario: Duplicate node names
- **WHEN** 不同提供商包含同名节点
- **THEN** 提供商状态按来源身份处理，不误隐藏仍有效来源的节点

### Requirement: Transactional validation and apply
The app SHALL 进行候选配置及订阅加载验证、文件快照检查、备份、原子写入、监控协调、运行结果核验和失败恢复。

#### Scenario: New source cannot load
- **WHEN** 新源不可达、格式无效、不能解析有效节点或应用后加载失败
- **THEN** 不宣告保存应用成功，保留或恢复旧配置及可恢复的运行态，并显示原因

#### Scenario: Preserve runtime settings
- **WHEN** 对当前运行配置应用提供商改动
- **THEN** 使用同进程配置重载，保留最新模式、端口、IPv6、TUN 和进程识别设置，核验 PID 与实际结果

#### Scenario: Provider connection impact
- **WHEN** 配置应用将重新初始化提供商
- **THEN** 明确告知关联连接可能关闭，测试包含真实提供商连接，不以 PID 不变代替连接连续性验证

### Requirement: Source and controller boundaries
The app SHALL 呈现本地文件、远程控制器及整份配置订阅的编辑边界。

#### Scenario: Remote controller
- **WHEN** 当前目标是只有标准 REST API 的远程核心
- **THEN** 保留运行摘要及已有刷新能力，不提供无法持久化的增删、停用或链接编辑

#### Scenario: Full configuration overwrite
- **WHEN** 编辑文件来自整份配置订阅
- **THEN** 提示覆盖更新可能移除本地提供商修改和禁用信息，不进行隐式重合并
