## 1. Quick Wins & Engineering 收口
- [x] 1.1 将终端代理快捷键从 `⌘C` 改为 `⇧⌘C`，释放标准复制
- [x] 1.2 连接页断开操作改为防误触菜单（全部断开二次确认 + 仅断开筛选结果）
- [x] 1.3 更新仓库地址至 `gyc-12/ClashBar` 并修复 `Scripts/package_app.sh` 新版 SwiftPM 产物定位
- [x] 1.4 节点页在停核 / 无配置 / 远程不可达时显示清晰状态引导卡

## 2. Settings: 原生 `dns.ipv6` 与默认测速链接
- [x] 2.1 实现原生 YAML `dns.ipv6` 读取与原子事务修改（含 `mihomo -t` 校验与重载回滚）
- [x] 2.2 系统设置页新增独立 `dns.ipv6` 开关与依赖提示
- [x] 2.3 实现可配置的默认测速 URL（支持 `gstatic` / `cp.cloudflare.com` 快捷预设）并接入测速与诊断视图

## 3. Group Editor 补完
- [x] 3.1 扩展 `NativeProxyProviderService` 支持新建策略组、编辑组类型、`use`、`include-all-providers`、`filter` / `exclude-filter` 及正则校验
- [x] 3.2 升级 `NativeGroupEditorView` 支持新建/编辑双模式、提供商勾选、正则输入与运行态节点实时匹配预览
- [x] 3.3 在策略组操作菜单补充「新建策略组」入口

## 4. Egress & Link Diagnostics
- [x] 4.1 扩展 `MihomoAPIService` 支持 `/dns/query`（A/AAAA）主动 DNS 查询
- [x] 4.2 实现代理出口 IPv4/IPv6 + ISP 探测、本机 IPv6 检测、核心配置摘要及 Claude 地区检测
- [x] 4.3 升级 `SiteReachabilityView` 整合出口与 IPv6 摘要、AI 三站地区检测与任意域名「为什么连不上」排查

## 5. Verification
- [x] 5.1 同步中英文本、补充单元测试与独立核心集成测试
- [x] 5.2 运行 `swift build`、`swift test`、独立核心集成测试、视觉快照复核、`make spec-check` 与 `make graph`
