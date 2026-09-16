# Codex Project Documentation Map

在会话启动、恢复、清空及上下文压缩后，向 Codex 注入整个项目的 `AGENTS.md` / `README.md` 路径地图。只扫描文件名，不读取正文；代理根据地图按需读取相关说明。

## 工作方式

- 使用一个同步 `SessionStart` hook，匹配 `startup|resume|clear|compact`。按官方契约，自动或手动压缩后，会在下一次模型请求前重新注入，包括同一轮中的继续执行。
- 根据会话工作目录查找 Git 工作树根目录；非 Git 项目或没有 Git 时使用会话工作目录。Bash 使用 hook 进程工作目录，PowerShell 使用事件的 `cwd`。
- 递归扫描，包含隐藏目录，文件名大小写不敏感。路径相对项目根目录排序；Bash 使用原生 `%q` 转义，PowerShell 使用 JSON 字符串转义，文件名中的换行不会伪造地图条目。
- 跳过 `.git`、`.hg`、`.svn`、`node_modules`、`.venv`、`venv`、`__pycache__` 目录及符号链接；其他目录均扫描，不使用 `.gitignore`，因此未跟踪和被忽略的项目文档也能出现。
- 每次重新生成，不缓存、不修改项目文件、不访问网络。子目录 AGENTS.md 的作用域仍限于该目录及其后代。
- `additionalContextLimit: 0` 保证地图完整注入，不由 Codex 转成预览。文档特别多的项目会相应占用更多上下文；扫描超过 15 秒则 hook 超时。

## 使用

| 平台 | 默认脚本 | 运行依赖 |
| --- | --- | --- |
| Linux / macOS | `scripts/project_map.sh` | Bash、系统 `find` 和 `sort` |
| Windows | `scripts/project_map.ps1` | PowerShell 7 (`pwsh`) |

无 Python、Node.js、jq 或第三方库运行依赖。Git 可选，用于从仓库子目录定位根目录。PowerShell 脚本也可在安装了 `pwsh` 的 Linux/macOS 上执行。Windows 自带的 Windows PowerShell 5.1 不在支持范围内。

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

测试使用 Python 标准库，无第三方测试框架；Python 仅用于开发验证。

```bash
python3 -m unittest discover -s tests -v
PROJECT_MAP_SHELL=pwsh python3 -m unittest discover -s tests -v
```

本地测试在 Linux 上执行配置中的两套 hook 命令，覆盖 Git 子目录、非 Git 项目、压缩后刷新、隐藏目录、符号链接和特殊文件名；不等同于 Windows 主机或真实 Codex 会话的压缩端到端验证。Bash 直接输出文本，PowerShell 输出 `hookSpecificOutput.additionalContext` JSON，二者均受 `SessionStart` 支持。

协议参考：[Codex Hooks](https://developers.openai.com/codex/hooks)、[插件打包](https://developers.openai.com/plugins/build/plugins)。
