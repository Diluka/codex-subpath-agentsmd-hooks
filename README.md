# Codex Project Documentation Map

在会话启动、恢复、清空及上下文压缩后，向 Codex 注入整个项目的 `AGENTS.md` / `README.md` 路径地图。代理根据地图按需读取相关说明。

## 工作方式

- 使用一个同步 `SessionStart` hook，匹配 `startup|resume|clear|compact`。按官方契约，自动或手动压缩后，会在下一次模型请求前重新注入，包括同一轮中的继续执行。
- 根据会话工作目录查找 Git 工作树根目录；非 Git 项目直接跳过。Bash 使用 hook 进程工作目录，PowerShell 使用事件的 `cwd`。
- 递归扫描，包含隐藏目录，匹配文件名的各种大小写形式。路径相对项目根目录排序；Bash 使用原生 `%q` 转义，PowerShell 使用 JSON 字符串转义。
- 直接在项目仓库运行 `git check-ignore --no-index`，使用 Git 原生忽略规则：各级 `.gitignore`、`.git/info/exclude` 和用户配置的全局规则。
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

将本目录作为插件加入你使用的 Codex 插件市场，然后安装并启用。安装后在 Codex CLI 的 `/hooks` 中审阅并信任 hook；再打开新任务验证。更新 hook 定义后需要重新信任，修改源码后也需要更新已安装的插件缓存。

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
```

GitHub Actions 在每次 push、PR 和手动触发时，使用 runner 自带工具运行以下组合：

| 系统 | 测试脚本 |
| --- | --- |
| Linux | Bash、PowerShell |
| Windows | PowerShell |
| macOS | 系统 `/bin/bash`、BSD `sort` |

测试覆盖 Git 子目录、非 Git 项目跳过、重新扫描、隐藏目录、排除规则和特殊文件名；换行目录名、FIFO 仅在 Unix 上验证。Bash 直接输出文本，PowerShell 输出 `hookSpecificOutput.additionalContext` JSON，二者均受 `SessionStart` 支持。

协议参考：[Codex Hooks](https://developers.openai.com/codex/hooks)、[插件打包](https://developers.openai.com/plugins/build/plugins)。
