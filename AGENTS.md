# ClashBar 开发约定

- 产品定位是原生 mihomo 管理面板。规则等持久化数据使用 mihomo 原生格式，保持配置可以脱离 App 运行。
- 功能改动先阅读 `openspec/config.yaml` 和相关 `openspec/changes/`，同步需求、设计和任务。用户提出方案讨论时先讨论，确认后继续实现。
- 使用 `make graph` 更新 CodeGraph，再通过 `npx --yes @colbymchenry/codegraph@1.6.2 explore <symbol>` 或 `impact <symbol>` 检查调用关系。`.codegraph/` 不提交。
- 用 `swift build`、相关 `swift test` 和 `make spec-check` 验证改动。真实核心集成测试使用独立进程和临时工作目录，不操作用户正在使用的核心。
- 新的界面文本同时维护 `zh-Hans` 和 `en`。其余流程见 `DEVELOPMENT.md`。
