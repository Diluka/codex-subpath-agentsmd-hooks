# Codex Project Documentation Map

在会话启动、恢复、清空及上下文压缩后，向 Codex 注入整个项目的 `AGENTS.md` / `README.md` 路径地图。只扫描文件名，不读取正文；代理根据地图按需读取相关说明。

## 工作方式

- 使用一个同步 `SessionStart` hook，匹配 `startup|resume|clear|compact`。按官方契约，自动或手动压缩后，会在下一次模型请求前重新注入，包括同一轮中的继续执行。
- 根据会话工作目录查找 Git 工作树根目录；非 Git 项目使用会话工作目录。Bash 使用 hook 进程工作目录，PowerShell 使用事件的 `cwd`。
- 递归扫描，包含隐藏目录，文件名大小写不敏感。路径相对项目根目录排序；Bash 使用原生 `%q` 转义，PowerShell 使用 JSON 字符串转义，文件名中的换行不会伪造地图条目。
- 排除规则依次选择项目根目录的 `.ignore`、`.gitignore`，都不存在时才使用插件的 `default.ignore`。只用选中的一个文件，不合并；空文件表示不排除。支持 Git ignore 的目录、通配符、`**`、`!`、注释和转义语法。
- `default.ignore` 包含原来的 `.git/`、`.hg/`、`.svn/`、`node_modules/`、`.venv/`、`venv/`、`__pycache__/`。项目提供规则文件时，这些默认项不再自动追加。符号链接和非普通文件始终不列入地图。
- 规则通过临时空仓库中的 Git 原生匹配器统一处理；进入目录前先判断，排除的目录不会递归扫描。不读取其他全局或子目录 ignore 文件。已跟踪文件、未跟踪文件和嵌套 Git 仓库中的文档同样按选中的规则过滤。
- 每次重新生成，不缓存、不修改项目文件、不访问网络。子目录 AGENTS.md 的作用域仍限于该目录及其后代。
- 临时数据位于系统临时目录的 `project-map-ignore-<项目绝对路径的 SHA-256>/run.<唯一标识>/`。同一项目共用固定父目录，每次运行独立，避免残留目录和并发 Git 初始化相互影响。运行脚本和测试均不主动清理临时目录，交由系统管理。
- `additionalContextLimit: 0` 保证地图完整注入，不由 Codex 转成预览。文档特别多的项目会相应占用更多上下文；扫描超过 15 秒则 hook 超时。

## 使用

| 平台 | 默认脚本 | 运行依赖 |
| --- | --- | --- |
| Linux / macOS | `scripts/project_map.sh` | Bash、Git、系统 `sort` 和 `sha256sum`（macOS 使用 `shasum`） |
| Windows | `scripts/project_map.ps1` | PowerShell 7 (`pwsh`)、Git |

无 Python、Node.js、jq 或第三方库运行依赖。Git 用于定位根目录和解析 ignore 规则，因此非 Git 项目也需要 Git 命令。PowerShell 脚本也可在安装了 `pwsh` 的 Linux/macOS 上执行。Windows 自带的 Windows PowerShell 5.1 不在支持范围内。

插件使用 `.codex-plugin/plugin.json` 和默认发现的 `hooks/hooks.json`。Codex 通过 `commandWindows` 选择 Windows 脚本，并在执行前替换 `${PLUGIN_ROOT}`。当前契约核验版本为 Codex CLI 0.154.0。

将本目录作为插件加入你使用的 Codex 插件市场，然后安装并启用。安装后在 Codex CLI 的 `/hooks` 中审阅并信任 hook；再打开新任务验证。更新 hook 定义后需要重新信任，修改源码后也需要更新已安装的插件缓存。

当前仓库只提供插件源码，不修改个人市场或自动安装。也可先直接验证输出：

```bash
bash scripts/project_map.sh
```

```powershell
@{ cwd = $PWD.Path; hook_event_name = 'SessionStart'; source = 'compact' } |
    ConvertTo-Json -Compress | pwsh -NoLogo -NoProfile -File scripts/project_map.ps1
```

## 开发验证

测试也使用原生 Bash / PowerShell，无 Python 或第三方测试框架：

```bash
bash tests/test_project_map.sh
pwsh -NoLogo -NoProfile -File tests/test_project_map.ps1
```

GitHub Actions 在每次 push、PR 和手动触发时运行以下组合，使用 runner 自带工具，无依赖安装步骤：

| 系统 | 测试脚本 |
| --- | --- |
| Linux | Bash、PowerShell |
| Windows | PowerShell |
| macOS | 系统 `/bin/bash`、BSD `sort` |

macOS 不能仅凭 Linux 通过就认定兼容：系统 Bash 版本、BSD 工具和文件系统大小写行为均可能不同，因此保留轻量原生测试。

测试覆盖 Git 子目录、非 Git 项目、重新扫描、隐藏目录、排除规则和特殊文件名；换行目录名、FIFO 仅在 Unix 上验证。它们验证脚本行为，不等同于真实 Codex 会话的压缩端到端验证。Bash 直接输出文本，PowerShell 输出 `hookSpecificOutput.additionalContext` JSON，二者均受 `SessionStart` 支持。

协议参考：[Codex Hooks](https://developers.openai.com/codex/hooks)、[插件打包](https://developers.openai.com/plugins/build/plugins)。
