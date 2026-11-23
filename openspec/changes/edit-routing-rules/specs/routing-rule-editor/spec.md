## ADDED Requirements

### Requirement: Native rule editing
The app SHALL 在分流页提供当前主配置每条规则的编辑入口，以原始文件条目为编辑来源并保留未修改规则的顺序和内容。

#### Scenario: Edit filtered duplicate
- **WHEN** 用户在搜索结果或按策略分组的列表中编辑一条与其他条目内容重复的规则
- **THEN** 仅修改对应原始索引的规则，不移动规则或修改其他重复条目

#### Scenario: Special rule
- **WHEN** 用户编辑 RULE-SET、DST-PORT、MATCH、SUB-RULE 或逻辑表达式
- **THEN** 编辑器根据类型展示适用字段，保留原参数，并由核心校验候选

### Requirement: Direct policy selection
The app SHALL 允许在规则行选择当前配置有效的代理组或内置策略，原位修改规则目标。

#### Scenario: Change rule target
- **WHEN** 用户将 RULE-SET 的策略从 OpenAI 改为 HK
- **THEN** 保存为该引用的新策略，影响该引用匹配的集合，不改变 OpenAI 组本身的节点选择

#### Scenario: Sub-rule target
- **WHEN** 规则为 SUB-RULE
- **THEN** 目标选择器展示子规则名，而不是代理组

### Requirement: Custom rule visibility
The app SHALL 在全部视图和自定义筛选中显示用原生 YAML 注释标记的自定义规则，规则生效不依赖标记或 App。

#### Scenario: Existing unmarked rule
- **WHEN** 已有规则没有可靠来源标记
- **THEN** 规则仍可见和可编辑，用户可明确标记为自定义，不根据位置自动判定

#### Scenario: Mark custom
- **WHEN** 用户将已有规则标记为自定义
- **THEN** 只修改注释和显示来源，不改变规则匹配顺序

### Requirement: Local source and runtime state
The app SHALL 在核心停止时显示本地规则，运行态与当前文件不一致时明确显示应用状态，不盲用运行态索引写文件。

#### Scenario: Core stopped
- **WHEN** 核心未运行但已选择有效的本地配置
- **THEN** 可以查看并编辑原生规则，保存后显示未运行状态

### Requirement: Validated save and recovery
The app SHALL 校验候选、检测并发修改、备份并原子保存，运行时应用且失败恢复，保留运行设置及已有自身文件监控机制。

#### Scenario: External change
- **WHEN** 编辑或校验期间配置被其他操作修改
- **THEN** 不覆盖新的内容，提示重新加载规则

#### Scenario: Apply failed
- **WHEN** 核心拒绝新配置
- **THEN** 恢复旧文件及运行态，恢复失败时展示备份路径

### Requirement: Apply without process restart
The app SHALL 在普通规则编辑时通过现有核心进程的配置重载应用，不主动重启进程或清空现有连接。

#### Scenario: Running core receives a rule edit
- **WHEN** 核心运行中且只有规则内容或策略发生变化
- **THEN** 使用 force=false 的配置重载，保留运行设置并避免目录监控触发额外进程重启

#### Scenario: Established TCP connection
- **WHEN** 独立集成测试在规则编辑前建立了持续传输的 TCP 连接
- **THEN** 验证应用过程中核心 PID 不变、该连接可继续传输且后续新连接使用新规则

### Requirement: Provider boundaries
The app SHALL 区分主配置 RULE-SET 引用与集合内部条件，不将 HTTP/MRS 缓存编辑作为持久化来源。

#### Scenario: Remote set exception
- **WHEN** 用户需要更改远程规则集内某个目标的策略
- **THEN** 可以新增更靠前的原生自定义规则并明确优先级，原引用和远程集合内容保持
