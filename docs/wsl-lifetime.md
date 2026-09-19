# WSL 停止导致 AgentDock 启动后掉线

## 这是什么问题

如果 `wsl.exe --list --verbose` 显示承载 Docker 的发行版 `Stopped`，同时 Windows 的 `/healthz` 超时，那么容器宿主已经停止。Windows 上 `tunnel-client` 仍可以轮询 OpenAI，所以可能同时出现 `AgentDock: STOPPED` 和 `Control Plane: CONNECTED`。

Microsoft 说明：systemd 服务本身不会保持 WSL 实例存活。Docker 的容器重启策略也不能启动已经停止的 WSL 宿主。这与“没有安装 WSL”不同；不要重新安装或注销发行版。

参考：[Microsoft 的 WSL systemd 说明](https://devblogs.microsoft.com/commandline/systemd-support-is-now-available-in-wsl/)。仅凭日志无法排除外部 `wsl --shutdown`、系统睡眠或 WSL 崩溃，但原脚本确实缺少独立的 WSL 保活会话。

## 更新与恢复

先确保没有安装/重启命令正在执行，在项目目录运行：

```powershell
git pull --ff-only origin main
```

拉取成功后：

```powershell
.\agentdock.cmd start
.\agentdock.cmd status
```

不需要再次 `install`，不需要删除 `.runtime`，不需要重填 Key 或重新拉取镜像。运行中的 Tunnel 会复用；现有容器由原来的启动流程恢复。

`docker-wsl` 模式新增独立的后台 `wsl.exe` 会话，里面只运行一个前台低开销等待脚本。在运行 Docker 预检/启动之前建立该会话，启动入口返回后它仍保持 Linux 命令运行。`start/restart/apply` 自动管理，不需要用户一直开着 Ubuntu 终端。

- 重复 start/restart 复用当前会话；PID、创建时间、可执行路径和随机标记共同验证身份。
- `stop` 先停止项目服务，再撤销本项目会话的 lease；不会执行 `wsl --shutdown` 或终止整个发行版。
- 启动或控制面检查失败时不会因为错误而立即撤销已建立的保活，便于查看日志；诊断后使用 `stop` 释放。
- `status` 只查询发行版清单，不为检查状态唤醒 WSL。
- 不自动改用 native、不改变默认发行版、不放宽目录挂载。
- 保活命令不需要 root，不接收 OpenAI API Key；不修改 `.wslconfig`、`/etc/wsl.conf` 或 Windows 的电源设置。

正常状态增加：

```text
WSL session : RUNNING (Ubuntu-22.04)
WSL distro  : RUNNING
```

保活日志位于 `.runtime/wsl-session.out.log` / `.runtime/wsl-session.err.log`。管理信息是 `.runtime/wsl-session.json` / `.runtime/wsl-session.lease`。不要在运行中移动整个安装目录；helper 和 lease 需要可从 WSL 访问。

## 验收

先 `start`，关闭所有 Ubuntu 交互终端，等待至少两分钟，再在 Windows PowerShell 执行：

```powershell
wsl.exe --list --verbose
curl.exe --noproxy "*" --connect-timeout 2 --max-time 5 -i http://127.0.0.1:18765/healthz
.\agentdock.cmd status
```

发行版应为 `Running`、健康接口为 HTTP 200，再在 ChatGPT 调用一次只读工具。端口非 18765 时按配置替换。

**保活不是开机自启，也不是不会掉线的保证。** Windows 重启、注销、显式 `wsl --shutdown`/`--terminate`、休眠、外部盘脱机或系统故障仍可能中断服务；恢复后再执行 `start`。本次不安装 Windows 计划任务，不自动覆盖用户的停止操作。

这些修改通过离线生命周期和真实 shell lease 测试验证；WSL/Docker/真实 Tunnel 端到端恢复仍需在目标机器验收。
