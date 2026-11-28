<div align="center">

<img src="./docs/public/clashbar-logo.png" width="220" alt="ClashBar Logo" />

# ClashBar

原生 macOS 菜单栏代理客户端，基于 `SwiftUI + AppKit`，由 `mihomo` 驱动。  
轻量、稳定，在菜单栏完成配置、节点、规则、连接与系统代理管理。 ✨

<p>
  <img alt="Platform" src="https://img.shields.io/badge/macOS-13%2B-111111?style=flat-square&logo=apple" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift" />
  <img alt="Build" src="https://img.shields.io/badge/Build-SwiftPM-0A84FF?style=flat-square" />
  <img alt="i18n" src="https://img.shields.io/badge/i18n-zh--Hans%20%7C%20en-34C759?style=flat-square" />
  <a href="https://github.com/Sitoi/ClashBar/releases" target="_blank" rel="noopener noreferrer">
    <img alt="Version" src="https://img.shields.io/github/v/release/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/stargazers" target="_blank" rel="noopener noreferrer">
    <img alt="Stars" src="https://img.shields.io/github/stars/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/issues" target="_blank" rel="noopener noreferrer">
    <img alt="Issues" src="https://img.shields.io/github/issues/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/pulls" target="_blank" rel="noopener noreferrer">
    <img alt="PRs" src="https://img.shields.io/github/issues-pr/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/network/members" target="_blank" rel="noopener noreferrer">
    <img alt="Forks" src="https://img.shields.io/github/forks/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/releases" target="_blank" rel="noopener noreferrer">
    <img alt="Downloads" src="https://img.shields.io/github/downloads/Sitoi/ClashBar/total?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/commits" target="_blank" rel="noopener noreferrer">
    <img alt="Commit Activity" src="https://img.shields.io/github/commit-activity/m/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/commits" target="_blank" rel="noopener noreferrer">
    <img alt="Last Commit" src="https://img.shields.io/github/last-commit/Sitoi/ClashBar?style=flat-square&logo=github" />
  </a>
  <a href="https://github.com/Sitoi/ClashBar/blob/main/LICENSE" target="_blank" rel="noopener noreferrer">
    <img alt="License" src="https://img.shields.io/github/license/Sitoi/ClashBar?style=flat-square" />
  </a>
</p>

<p>
  🌐 <a href="https://clashbar.sitoi.workers.dev"><strong>文档站</strong></a>
  ·
  📦 <a href="https://github.com/Sitoi/ClashBar/releases"><strong>Releases</strong></a>
  ·
  💬 <a href="https://t.me/clashbars"><strong>Telegram</strong></a>
</p>

</div>

<p>
  <img src="./docs/public/clashbar-black.png" width="49%" alt="ClashBar Dark" />
  <img src="./docs/public/clashbar-light.png" width="49%" alt="ClashBar Light" />
</p>

## ✨ 特点

- 🪶 **轻量**：去掉 Core 约 3 MB 内
- 🧭 **菜单栏优先**：配置导入/更新、节点切换、延迟测试、规则与连接排障
- 🔐 **系统集成**：系统代理、开机启动
- 📊 **可观测**：实时流量、连接、内存、日志过滤
- 🌍 **中英双语**：简体中文 / English

### 📏 体积对比（macOS Finder 显示值，仅供参考）

| 客户端                 |     体积 |
| ---------------------- | -------: |
| ClashBar.app (No Core) |     3 MB |
| ClashMac.app           |  75.2 MB |
| Clash Verge.app        | 128.4 MB |
| Clash Party.app        | 496.7 MB |

## 📦 安装

**要求：** macOS 13+ 🍎

```sh
brew tap Sitoi/tap
brew install --cask clashbar
```

或从 [Releases](https://github.com/Sitoi/ClashBar/releases) 下载 `.dmg`，将 `ClashBar.app` 拖入 `/Applications`。

卸载：

```sh
brew uninstall --cask clashbar
# 同时清除数据
brew uninstall --zap --cask clashbar
```

> [!IMPORTANT]
>
> - ⚠️ 同一时间只让一个 mihomo / Clash 系客户端接管系统代理。
> - 📂 系统代理依赖打包后的 `.app`；请放到 `/Applications` 后再使用。
> - 🔑 第一次开启系统代理时输入管理员密码。helper 会装到系统目录，之后更新 app 不会让它失效。开机启动仍需在登录项中允许 ClashBar。
> - 🔄 系统代理开关异常时，在应用内重新打开一次；必要时 `Restart` 内核。若系统弹出后台项目提示，在登录项里允许该 helper。

## 🚀 快速上手

1. 🖱️ 点击菜单栏图标打开面板
2. 📥 在 Proxy 选择或导入配置
3. ▶️ `Start` / `Restart` 启动内核
4. 🎛️ 选择模式：`Rule` / `Global` / `Direct`
5. 📶 切换节点并测速，确认可用后再开系统代理

更多说明见文档站：📖 [快速开始](https://clashbar.sitoi.workers.dev/docs/quick-start) · [功能说明](https://clashbar.sitoi.workers.dev/docs/features) · [故障排查](https://clashbar.sitoi.workers.dev/docs/troubleshooting)

## 🗺️ 功能一览

| 页面           | 内容                                            |
| -------------- | ----------------------------------------------- |
| 🧭 Proxy       | 配置、模式、系统代理、节点切换、延迟与代理提供商管理 |
| 📚 Rules       | 规则统计、筛选、Provider 更新、快捷添加分流规则 |
| 🌐 Connections | 连接过滤与关闭                                  |
| 🪵 Logs        | 级别过滤、关键词检索                            |
| ⚙️ System      | 语言、状态栏、端口、`allow-lan` / `ipv6` 等     |

在 **Proxy → 代理提供商** 点 `+` 添加 mihomo 节点订阅。每行可刷新、启停，或通过 `…` 修改链接和删除。禁用后仍可在面板找到该提供商；应用后，它的节点退出代理组。禁用信息存在原 YAML 的注释里，配置可脱离 ClashBar 使用。操作导致组没有可用节点时，面板会要求选择回退。

本地配置支持管理，远程核心支持查看和刷新。应用属于同一进程内的配置重载，经代理提供商的连接可能断开。更新整份配置订阅可能覆盖这些本地改动。

- **编辑策略组**：在组的节点菜单点铅笔，或在「策略组 → … → 编辑策略组」选本地组。添加 `us` 到 `proxy` 会保存对子组的引用，而非复制其节点，支持调整成员顺序；删除与移除成员是不同操作，仍有引用时会列出位置并阻止删除。
- **折叠超时节点**：最近三次独立测速都超时的节点会进入列表底部的可展开区；当前选中项、子组和未测速节点保留。恢复成功即回到正常区。可在策略组选项关闭此功能。
- **站点连通性**：「策略组 → … → 站点连通性」中，Gemini 和 ChatGPT 通过当前核心的代理端口和实际路由检查匿名网页的地区可用性，显示支持信号、地区受限或无法确认。仅有延迟、HTTP 200 或登录/验证页面不算地区支持；无法连接代理端口时不会回退到本机直连。下方选组用于检测 ChatGPT 和 YouTube 的 HTTPS 2xx/3xx 连通性，不代表可登录或播放。
- **新建与编辑 HTTP 订阅**：新建时名称和链接必填，可选项默认更新间隔 `3600` 秒（支持设为 `0` 手动更新）、健康检查 `https://cp.cloudflare.com` 每 `300` 秒、下载策略 `DIRECT`、默认 User-Agent 列表，不预设节点前缀（留空不写 `override`），缓存路径自动分配。编辑已有提供商支持重命名（同步更新策略组引用）及调整所有上述选项。直连加载失败时若已有 `proxy` 或主代理选择组会重试一次，仅在成功时保存该下载策略。

📁 运行时数据目录：`~/Library/Application Support/clashbar`  
🧩 内置内核会复制到：`~/Library/Application Support/clashbar/core/mihomo`

## 🛠️ 开发构建

```sh
# 依赖：Xcode / Swift 6.2+、macOS 13+
make build                 # 产出 dist/ClashBar.app（默认不含 Core）
make build WITH_CORE=1     # 打包内置 mihomo
make dist WITH_CORE=1      # app + dmg
```

需求和代码关系使用 OpenSpec / CodeGraph 管理，见 [开发工作流](./DEVELOPMENT.md)。快捷添加的规则直接保存为 mihomo 原生配置，使用方式见 [快捷分流规则](./docs/content/docs/quick-routing-rules.mdx)。

## 🙌 社区

- 🌐 文档：<https://clashbar.sitoi.workers.dev>
- 💬 Telegram：<https://t.me/clashbars>
- 🐛 Issue / PR：欢迎反馈与贡献

## 👥 贡献者

[![Contributors](https://contrib.rocks/image?repo=Sitoi/ClashBar)](https://github.com/Sitoi/ClashBar/graphs/contributors)

## 🙏 致谢

感谢 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) 提供内核能力。
感谢 [Linux DO](https://linux.do/) 社区的支持与帮助 🙏

## ⭐ Star 趋势

[![Star History Chart](https://star-history.dera.page/svg?repos=Sitoi/ClashBar&type=date&legend=top-left)](https://star-history.dera.page/#Sitoi/ClashBar&type=date&legend=top-left)
