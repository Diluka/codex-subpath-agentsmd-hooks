# Codex Project Documentation Map

在会话启动、恢复、清空及上下文压缩后，向 Codex 注入整个项目的 `AGENTS.md` / `README.md` 路径地图。代理根据地图按需读取相关说明。

## 工作方式

- 使用一个同步 `SessionStart` hook，匹配 `startup|resume|clear|compact`。按官方契约，自动或手动压缩后，会在下一次模型请求前重新注入，包括同一轮中的继续执行。
- 根据会话工作目录查找 Git 工作树根目录；非 Git 项目直接跳过。Bash 使用 hook 进程工作目录，PowerShell 使用事件的 `cwd`。
- 递归扫描，包含隐藏目录，匹配文件名的各种大小写形式。路径相对项目根目录排序；Bash 使用原生 `%q` 转义，PowerShell 使用 JSON 字符串转义。
- 优先使用项目根目录的 `.ignore`（Git 忽略语法；空文件表示不排除任何路径）。存在该文件时，仅使用其规则；否则运行 `git check-ignore --no-index`，回退到 Git 默认规则：各级 `.gitignore`、`.git/info/exclude` 和用户配置的全局规则。
- 进入目录前先判断并跳过被忽略的目录。忽略规则同样应用于已跟踪文件；嵌套仓库中的文档也会扫描。始终跳过 `.git`、符号链接和非普通文件。
- 每次重新生成地图。子目录 AGENTS.md 的作用域限于该目录及其后代。
- `additionalContextLimit: 0` 保证地图完整注入。文档特别多的项目会相应占用更多上下文；扫描超过 15 秒则 hook 超时。

## 使用

| 平台 | 默认脚本 | 运行依赖 |
| --- | --- | --- |
| Linux / macOS | `scripts/project_map.sh` | Bash、Git、系统 `sort` |
| Windows | `scripts/project_map.ps1` | PowerShell 7 (`pwsh`)、Git |

Git 用于定位根目录和解析忽略规则。PowerShell 脚本也可在安装了 PowerShell 7 (`pwsh`) 的 Linux/macOS 上执行。

插件使用 `.codex-plugin/plugin.json` 和默认发现的 `hooks/hooks.json`。Codex 通过 `commandWindows` 选择 Windows 脚本，并在执行前替换 `${PLUGIN_ROOT}`。当前契约核验版本为 Codex CLI 0.154.0。

通过仓库自带的市场安装：

```bash
codex plugin marketplace add Diluka/codex-subpath-agentsmd-hooks
codex plugin add codex-subpath-agentsmd-hooks@codex-subpath-agentsmd-hooks
```

仓库的 `.agents/plugins/marketplace.json` 指向根目录中的插件。也可以在 Codex 的添加市场入口填写仓库地址。

安装后在 Codex CLI 的 `/hooks` 中审阅并信任 hook，再打开新任务验证。更新 hook 定义后需要重新信任，修改源码后也需要更新已安装的插件缓存。

也可先直接验证输出：

```bash
bash scripts/project_map.sh
```

```powershell
@{ cwd = $PWD.Path; hook_event_name = 'SessionStart'; source = 'compact' } |
    ConvertTo-Json -Compress | pwsh -NoLogo -NoProfile -File scripts/project_map.ps1
```

## 开发验证

测试使用原生 Bash / PowerShell：

```bash
bash tests/test_project_map.sh
pwsh -NoLogo -NoProfile -File tests/test_project_map.ps1
pwsh -NoLogo -NoProfile -File tests/test_nested_git_e2e.ps1 -Shell bash
pwsh -NoLogo -NoProfile -File tests/test_nested_git_e2e.ps1 -Shell pwsh
```

GitHub Actions 在每次 push、PR 和手动触发时，使用 runner 自带工具运行以下组合：

| 系统 | 测试脚本 |
| --- | --- |
| Linux | Bash、PowerShell |
| Windows | PowerShell |
| macOS | 系统 `/bin/bash`、BSD `sort` |

Linux 和 Windows 还会使用 Node.js LTS 安装最新版 Codex CLI，在独立配置目录中运行 `tests/test_plugin_install.ps1`：添加仓库市场、安装插件、检查安装文件和启用状态，并执行已安装的 PowerShell hook 验证地图输出。

端到端测试使用本地 Git 仓库构造多层嵌套仓库、真实子模块和导入的子树，复现 `.gitignore` 排除 `apps/*`、`.ignore` 放行子项目的工作空间。逐项比较完整文档清单，验证遗漏、误收录以及删除 `.ignore` 后的回退行为，并沿用 hook 的 15 秒超时。上述跨平台组合和插件安装测试均运行该场景；安装测试直接验证安装后的脚本。Bash 端到端测试需要 Unix 环境，测试驱动需要 PowerShell 7。

测试覆盖 Git 子目录、非 Git 项目跳过、重新扫描、隐藏目录、排除规则和特殊文件名；换行目录名、FIFO 仅在 Unix 上验证。Bash 直接输出文本，PowerShell 输出 `hookSpecificOutput.additionalContext` JSON，二者均受 `SessionStart` 支持。

协议参考：[Codex Hooks](https://developers.openai.com/codex/hooks)、[插件打包](https://developers.openai.com/plugins/build/plugins)。
