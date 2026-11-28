## Why

用户需要更顺手的面板基础交互（避免 `⌘C` 与断开全部连接误触、停核清晰引导、正确的仓库更新源与构建脚本）、在不手改 YAML 的情况下控制原生 `dns.ipv6` 与默认测速链接、完整创建和配置策略组（含 `use` 订阅绑定与正则过滤），以及在排查家宽/AI 节点时一站式诊断出口 IP、IPv6、核心 DNS 解析与站点可用性。

## What Changes

- **体验与工程收口**：`⌘C` 归还标准复制（终端命令复制改为 `⇧⌘C`）；连接页将「断开全部连接」放入带确认提示的操作菜单并支持仅断开当前筛选连接；更新检查与发布链接指向 `gyc-12/ClashBar`；打包脚本改用 `swift build --show-bin-path`；核心停止或远程不可达时，节点页顶部展示清晰状态与下一步操作引导。
- **原生 `dns.ipv6` 与测速 URL 设置**：系统设置页新增独立的原生 `dns.ipv6` 开关（不绑定顶层 `ipv6`，写入原生 YAML 并重载核心，附带网络 IPv6 与重载提示）；新增可配置的默认手动测速链接（内置 `gstatic` / `cp.cloudflare.com` 快捷预设）。
- **策略组编辑器补完**：支持新建策略组，以及在编辑/新建策略组时设置组类型（`select` / `url-test` / `fallback` / `load-balance`）、绑定 `use` 订阅提供商与 `include-all-providers`、编辑 `filter` / `exclude-filter` 正则并实时预览匹配的运行态节点。
- **出口与链路诊断工具**：在站点与出口诊断弹窗中新增代理 IPv4/IPv6 出口与归属 ISP、本机 IPv6 状态、当前核心 IPv6/Fake-IP/DNS 配置摘要、Claude 地区检测，以及输入任意域名的核心主动 DNS 查询（A/AAAA）与按组连通性排查。

## Capabilities

### New Capabilities
- `panel-diagnostics-and-groups`: 面板基础交互收口、原生 `dns.ipv6` 与测速 URL 配置、完整策略组编辑与创建、出口与链路诊断工具。

## Impact

涉及菜单栏快捷键、连接页、节点页、系统设置页、策略组编辑器、站点诊断面板、mihomo API 客户端、原生 YAML 编辑服务、打包脚本、中英文文案及测试，不新增私有配置数据库。
