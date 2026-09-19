# Windows 启动入口与状态排障

## 更新后重启

在项目目录内的 PowerShell 执行：

```powershell
git pull --ff-only origin main
```

确认拉取成功后再执行（不要在更新脚本文件的同时执行重启）：

```powershell
.\agentdock.cmd restart
.\agentdock.cmd status
```

本次入口修复**不需要重装镜像、不需要更换 Key、不需要删除 `.runtime/` 或重填 `config.yaml`**。若 Git 报本地修改冲突，先保存并处理修改，不要执行 `reset --hard` 或 `git clean`。

## 如何看结果

| 输出 | 含义 |
|---|---|
| `AgentDock : RUNNING` | 本地健康检查通过 |
| `Tunnel : RUNNING` | 当时 Tunnel PID 对应的进程存在；不等于已连通 |
| `Control Plane : CONNECTED` | 当前记录的 Tunnel 进程拥有本地 8080 metrics 监听，且有近期成功轮询证据 |
| `Control Plane : UNVERIFIED` | 尚未取得足够证据；可能是网络/代理/权限、metrics 未启用或端口变化，也可能是本地进程未运行 |

`start/restart/apply` 的退出码：`0` 表示启动命令和上述轮询检查通过；`2` 表示本地命令完成但轮询未验证（或用法不正确，会有单独提示）；其他非零值表示某一步失败。退出码 `2` 不会自动停止已经启动的服务。

在执行命令后立即查看 `$LASTEXITCODE`，不要在这之前执行其他原生命令。`status` 查询执行成功时返回 `0`，不代表所有服务健康。最终仍需在 ChatGPT 中调用一次只读工具验证完整链路。

初始化容器 `agentdock-init` 完成后显示 `Exited` 是预期行为；主容器应正常运行。

## CMD 出现 `.ps1" restart` 等残片

当前修复把 CMD 入口缩减为一次有引号的 PowerShell 调用，并将调用和退出放在同一解析块中；后续流程由 PowerShell 的 `-File` 和参数数组调用。Git 强制 `.cmd` 使用 CRLF，入口仅包含 ASCII、无 BOM。

这防止重复分段调用、路径重新解析，以及子进程运行期间入口文件被替换后继续读取到错误文件偏移。**并不表示仅凭一条残片日志就能认定原始机器的具体根因。** 不应在脚本执行过程中另开终端 `git pull` 或编辑启动文件。

本地入口文件仍异常时，可以暂时绕过 CMD：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows-entry.ps1 status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows-entry.ps1 restart
```

查看日志：

```powershell
.\agentdock.cmd logs
```

新版 `help/status/stop/logs` 不触发 Tunnel 下载。代理先于下载准备生效；入口只显示代理来源，不打印含用户名和密码的代理 URL。失败不自动倾倒日志；分享日志前仍需检查和遮盖 Key、Token、代理密码。

## 测试范围

Windows CI 使用真实 CMD 和 Windows PowerShell 5.1、临时项目目录及模拟后端，检查路径（空格、中文、括号、`&`、`!`）、参数传递、退出码、入口被更新后的退出、下载/主脚本失败、状态检查与代理脱敏。Linux/macOS 继续执行原有下载回归。

这些是离线控制流程测试，不使用真实 Key、不连接你的 WSL，也不代替真实 Docker + OpenAI 端到端验收。目录挂载、Docker/native 部署选择和自动启动功能没有在这次修复中更改。
