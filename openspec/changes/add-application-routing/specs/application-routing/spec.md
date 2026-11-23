## ADDED Requirements

### Requirement: Application and observed process selection
The app SHALL 支持搜索已安装应用和已观测连接进程，选择 .app 或手动输入，并预览实际可执行路径或进程名。

#### Scenario: Installed application
- **WHEN** 用户选择有效应用 Bundle
- **THEN** 默认使用主可执行文件绝对路径，展示 Helper 范围说明

#### Scenario: Connection process is unknown
- **WHEN** 连接没有进程路径或进程名
- **THEN** 不从域名猜测应用，不提供预填进程入口

### Requirement: Native exact process rules
The app SHALL 支持 PROCESS-NAME / PROCESS-PATH 和可搜索策略，持久化到原生主配置 rules。

#### Scenario: Save a process rule
- **WHEN** 用户确认保存
- **THEN** 规则置顶并替换同类型同条件项，其他规则顺序不变，标记为自定义

#### Scenario: Invalid target
- **WHEN** 条件含逗号、控制字符或路径不是绝对路径
- **THEN** 禁用保存，不将应用名称转换为域名规则

### Requirement: Explicit process lookup setting
The app SHALL 展示进程识别状态，并仅根据用户的明确编辑选择将 strict 持久化和应用。

#### Scenario: Process lookup is off
- **WHEN** 配置或当前有效运行态的进程识别为 off
- **THEN** 提供可见的启用选择，未启用时阻止无效规则应用

#### Scenario: Enable and reload
- **WHEN** 用户选择启用 strict 并保存
- **THEN** 原生配置和运行态均为 strict，其余运行设置保持；失败恢复原文件和原运行态

### Requirement: Transactional local save
The app SHALL 复用校验、备份、原子写入和并发保护，不主动关闭连接或重启核心。

#### Scenario: Stopped core or inactive file
- **WHEN** 核心停止或编辑文件不是当前运行配置
- **THEN** 保存本地配置并明确未应用，不替换其他运行配置

#### Scenario: Remote controller
- **WHEN** 管理远程机器
- **THEN** 禁用本地应用规则写入并说明原因

#### Scenario: Subscription source
- **WHEN** 编辑整份订阅配置
- **THEN** 提示订阅覆盖会移除本地编辑，不隐式合并
