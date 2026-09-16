# Personal Scoop bucket

[![CI](https://github.com/pilgrimlyieu/scoop-buckets/actions/workflows/ci.yml/badge.svg)](https://github.com/pilgrimlyieu/scoop-buckets/actions/workflows/ci.yml)
[![Update manifests](https://github.com/pilgrimlyieu/scoop-buckets/actions/workflows/update.yml/badge.svg)](https://github.com/pilgrimlyieu/scoop-buckets/actions/workflows/update.yml)

自用 Windows Scoop bucket，收录需要的预发布渠道和少量安装配置调整，使用标准 Scoop 字段。

## 使用

在 Windows PowerShell 中添加：

```powershell
scoop bucket add personal https://github.com/pilgrimlyieu/scoop-buckets
```

按需安装：

```powershell
scoop install personal/focust
```

| 清单 | 渠道与定制 | 架构 |
| --- | --- | --- |
| `anki-latest` | 有 Windows 包的最高可用版本，包含 alpha、beta、RC；数据放在 Scoop persist | x64 |
| `neovide-nightly` | 官方 nightly ZIP；版本号包含 Windows 构建时间与资产 ID | x64 |
| `focust` | 上游稳定版便携 ZIP，补齐 Windows 通知身份，保留原有 AppData 配置位置 | x64 |
| `neovim` | 稳定版，提供 `nvim`、`xxd`、`win32yank` | x64、ARM64 |
| `neovim-nightly` | nightly，提供同样的命令；构建 ID 可识别同一提交的重新打包 | x64、ARM64 |

Focust 的安装钩子会给 Scoop 创建的快捷方式写入 Windows 通知所需的应用身份。普通 `scoop reset focust` 保存已有快捷方式时会保留该属性。如果已安装旧清单中的同版本，或快捷方式被删除后重建，更新 bucket 并退出 Focust 后执行 `scoop update focust --force`，重新应用安装钩子。

## 维护与验证

工具会自动取得固定版本的 Scoop 核心，下载文件、配置、测试安装和日志全部放在本仓库 `.local/`，不使用当前机器的 Scoop 安装。命令结束后恢复进程环境变量。

```powershell
# 格式、PowerShell 语法、官方 schema、版本选择及发布一致性测试
.\bin\test.ps1

# 仅查询上游版本
.\bin\checkver.ps1

# 暂存更新，校验上游资产，检查实际安装包，全部通过后写回清单
.\bin\update.ps1

# 只处理一个应用
.\bin\update.ps1 -App focust
```

完整安装包测试需要 Windows 本地文件系统创建 junction。WSL 的 UNC 路径可执行静态检查，ZIP 包可用 `test-packages.ps1 -ArchiveOnly`；对应的本地更新可用 `update.ps1 -App <名称> -ArchiveOnly`，随后由 CI 完成集成验证。

自动更新工作流每小时检查一次，也可在 GitHub Actions 手动运行。它在临时目录更新，验证版本、下载地址和哈希属于同一份上游发布，检查变更软件包后才提交。使用仓库自带的 `GITHUB_TOKEN`，无需额外 PAT；机器人提交前已经运行检查，不依赖随后再触发一次 push CI。

提交信息会记录具体变化：单个软件使用 `focust: 0.4.0 -> 0.4.1`；多个软件更新时，标题列出软件名，正文逐项列出旧版本和新版本。同版本的哈希、下载地址或解包设置变化也会明确注明。

Actions 日志按检查阶段和软件包分组折叠，用青色显示检查信息、绿色显示通过、黄色显示更新、红色显示失败，并保留文字标签。CI 分别检查 Windows 自带的 PowerShell 5.1 和 PowerShell 7 的兼容性；安装包集成测试和自动更新使用 PowerShell 7。

上游 nightly 使用滚动下载地址。上游换包到本 bucket 刷新之间可能暂时出现 hash 不匹配；刷新 bucket 后重试，保留校验。没有本地缓存时，上游删除的旧 nightly 不保证可以重新下载。

## 来源

安装布局参考 [ScoopInstaller/Extras](https://github.com/ScoopInstaller/Extras)、[Main](https://github.com/ScoopInstaller/Main) 和 [Versions](https://github.com/ScoopInstaller/Versions)。Anki 基于官方 MSI 清单调整预发布版本选择；Neovim 基于官方两种渠道增加命令入口；Focust 与 Neovide nightly 直接采用项目发布的 ZIP。当前可安装版本以 `bucket/` 为准。

本仓库采用 [Unlicense](LICENSE)。各软件的许可由相应 manifest 的 `license` 字段说明。
