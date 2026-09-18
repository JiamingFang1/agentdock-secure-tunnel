# AgentDock Secure Tunnel

让 **AgentDock** 通过 **OpenAI Secure MCP Tunnel** 接入 ChatGPT。

默认推荐 Docker 隔离：

```text
ChatGPT → Secure MCP Tunnel → tunnel-client（宿主机） → AgentDock（Docker） → 指定 workspaces
```

支持 Windows、macOS、Linux，amd64 / arm64。

## 1. 创建 OpenAI Tunnel

打开：<https://platform.openai.com/settings/organization/tunnels>

1. 点击 **Create tunnel**。
2. 填写名称、描述等信息。
3. 创建完成后复制 **Tunnel ID**。

![OpenAI Platform 创建 Tunnel](docs/images/image.png)

## 2. 创建 Runtime API Key

打开：<https://platform.openai.com/settings/organization/api-keys>

创建 **Restricted Runtime API Key**，确保具备：

```text
Tunnels: Read
Tunnels: Use
```

保存生成的 API Key。

![OpenAI Platform Runtime API Key / Tunnel 权限配置](docs/images/image2.png)

## 3. Clone 与配置

```bash
git clone https://github.com/JiamingFang1/agentdock-secure-tunnel.git
cd agentdock-secure-tunnel
```

Windows：

```powershell
Copy-Item config.example.yaml config.yaml
```

macOS / Linux：

```bash
cp config.example.yaml config.yaml
```

> 复制示例配置仅用于首次配置；已经填写过 `config.yaml` 时不要覆盖它。

编辑 `config.yaml`：

```yaml
# auto = 优先使用 Docker
deployment_mode: 'auto'

# OpenAI Tunnel ID
tunnel_id: 'TUNNEL_ID_HERE'

# Restricted Runtime API Key
runtime_api_key: 'RUNTIME_API_KEY_HERE'

# AgentDock 本地端口，一般保持默认
agentdock_port: 18765

# 默认工作区名称：填写默认 path 的最后一级目录名
default_workspace: 'my-project'

workspaces:
  # WSL / Linux / macOS 目录
  - path: '/home/<user>/projects/my-project'
    mode: 'rw'

  # Windows 目录
  - path: 'D:\workspace\shared-data'
    mode: 'rw'
```

把 `Tunnel ID`、`Runtime API Key` 和 workspace 路径替换成自己的实际值即可。

## 4. 安装并启动

### Windows

```powershell
.\agentdock.cmd install
.\agentdock.cmd start
```

Windows 安装器会自动检测容器运行时：

```text
Docker Desktop 正常运行
        ↓
直接使用 docker-windows

Docker Desktop 已安装但未启动
        ↓
选择：启动 Docker Desktop / 使用 WSL Docker / native / 取消

没有可用 Docker Desktop
        ↓
检查 WSL Docker
        ↓
WSL 有发行版但没有 Docker → 可安装/修复 Docker Engine
WSL 没有可用发行版        → 可安装 WSL + Ubuntu
所有 Docker 方案都不用   → 可选择 native，并显示安全风险
```

> WSL 本身通常 **不自带 Docker Engine**。WSL 中能直接执行 `docker`，常见原因是 Docker Desktop 开启了 WSL integration，或用户之前自行安装过 Docker Engine。

自动安装 Docker Engine 目前支持 Ubuntu / Debian WSL，并使用 Docker 官方 APT 仓库。安装 WSL + Ubuntu 可能需要管理员权限、Windows 重启，以及首次打开 Ubuntu 创建 Linux 用户；完成后重新运行 `.\agentdock.cmd install` 即可。

### macOS / Linux

先准备 **Python 3.8+、curl**；使用 Docker 隔离时，还需先安装并启动 Docker Engine，确保 `docker compose` 可用。macOS / Linux 安装器不会自动安装 Docker。下载器只使用 Python 标准库，无需额外 Python 包。

在仓库目录安装、启动：

```bash
./agentdock install
./agentdock start
./agentdock status
```

新版 `agentdock` 已在 Git 中标记为可执行。ZIP 解压或旧 checkout 仍提示 `permission denied` 时，可改用：

```bash
bash ./agentdock install
bash ./agentdock start
```

**旧版本更新后重新安装**（保留已有配置和运行数据）：

```bash
git -c core.fileMode=false pull --ff-only origin main &&
./agentdock install &&
./agentdock start
```

`core.fileMode=false` 仅对这次 pull 生效，用于忽略之前手动 `chmod` 造成的纯权限变化；不会强制覆盖本地内容修改。若 Git 提示冲突，先处理冲突，不要用 `reset --hard`。**不需要删除 `.runtime/`，也不需要重填 `config.yaml`。**

下载过程会显示查询、下载、SHA-256 校验等阶段；网络请求有超时和错误提示。已有可运行的 tunnel-client 会复用。看到 `Installed in ... mode` 才表示安装流程完成，安装不会代替 `start`。

权限、Python 依赖、网络代理或下载失败的详细处理见：[macOS / Linux 安装排障](docs/macos-install.md)。

正常启动后会看到类似：

```text
AgentDock : RUNNING
Tunnel    : RUNNING
Mode      : docker-wsl
Default   : my-project -> /home/agentdock/AgentDock/workspaces/my-project
MCP       : http://127.0.0.1:18765/mcp
```

> 上面是 Windows + WSL 的输出示例；macOS / Linux Docker 模式显示 `Mode: docker`。本地进程状态不等于端到端连接验证，仍需在 ChatGPT 中调用一次只读工具。

以后修改 `config.yaml` 后，直接执行：

Windows：

```powershell
.\agentdock.cmd apply
```

macOS / Linux：

```bash
./agentdock apply
```

## 5. ChatGPT 网页端配置

保持 AgentDock 与 `tunnel-client` 运行，然后在 ChatGPT 网页端打开 **Settings → Apps / Connectors**（具体名称可能随 UI 版本变化）。

1. 新建 Custom MCP / App Connection。
2. **Connection** 选择 **Tunnel**。
3. 选择第 1 步创建的同一个 Tunnel。
4. 保存并让 ChatGPT 加载 AgentDock 暴露的 MCP tools。

![ChatGPT 网页端 Tunnel / MCP App 配置](docs/images/image3.png)

完成后即可在 ChatGPT 中调用 AgentDock。

---

# 补充说明

下面内容不是首次安装必读，遇到配置、目录或权限问题时再查看即可。

## workspace 名称与默认目录

默认不需要写 `name`。脚本自动使用 `path` 的最后一级目录名作为 workspace 名称：

```text
/home/<user>/projects/my-project
→ my-project

D:\workspace\shared-data
→ shared-data
```

Docker 模式下对应：

```text
/home/agentdock/AgentDock/workspaces/my-project
/home/agentdock/AgentDock/workspaces/shared-data
```

如果配置：

```yaml
default_workspace: 'my-project'
```

则 AgentDock 的真实默认工作目录就是：

```text
/home/agentdock/AgentDock/workspaces/my-project
```

即：

```text
AGENTDOCK_DEFAULT_DIR=/home/agentdock/AgentDock/workspaces/my-project
```

旧版配置中的 `name` 仍然兼容，但新配置建议省略。

## workspace 读写模式

```text
rw = 可读写
ro = 只读
```

默认 workspace 必须使用：

```yaml
mode: 'rw'
```

因为 AgentDock 启动时会对默认目录执行自身的权限保护逻辑。

## Windows + WSL 混合目录

Windows 配置中可以同时使用 Windows 原生路径和 WSL 路径：

```yaml
workspaces:
  - path: 'D:\workspace\windows-project'
    mode: 'rw'

  - path: '/home/<user>/projects/linux-project'
    mode: 'rw'
```

存在 `/home/...` 这类 WSL 路径时，Docker 模式会使用 **WSL Docker Engine**。

Windows 路径会自动转换：

```text
D:\workspace\windows-project
→ /mnt/d/workspace/windows-project
```

WSL 路径保持原样。

## Docker 权限模型

Docker 模式会处理常见的 Linux / WSL UID/GID 权限问题：

- Linux / macOS：AgentDock 使用当前宿主用户的 UID/GID 运行；
- Windows + WSL Docker：AgentDock 使用默认 WSL 用户的 UID/GID 运行；
- AgentDock 内部 volume 由一次性 init 容器调整权限；
- 不会对所有 workspace 执行 `chown -R` 或 `chmod 777`。

Windows + WSL 下，启动前会检查：

```text
WSL Docker 是否可用
默认 WSL 用户 UID/GID
workspace 是否可读/可进入
rw workspace 是否可写
default_workspace 是否存在并为 rw
```

`apply` 会先完成预检，预检失败时不会先停止当前正在运行的服务。

## deployment_mode

```yaml
deployment_mode: 'auto'
```

可选值：

```text
auto    优先 Docker；所有 Docker 方案不可用时可显式确认 native 风险
docker  强制 Docker，不允许 native fallback
native  直接宿主机运行 AgentDock
```

推荐使用 Docker。

## Docker 与 native 的区别

### Docker

只把 `config.yaml` 中声明的目录挂载给 AgentDock：

```text
Host
├── /home/<user>/projects/my-project
│   → /home/agentdock/AgentDock/workspaces/my-project
│
└── D:\workspace\shared-data
    → /home/agentdock/AgentDock/workspaces/shared-data
```

未挂载的宿主机目录不会因为本项目配置自动暴露给 AgentDock。

### native

native 模式没有容器目录隔离，也无法强制执行 `ro/rw` workspace 权限。

> Native AgentDock 的 file / shell tools 以当前宿主机用户权限执行，可能读取、修改或删除 `workspaces` 之外的文件。`AGENTDOCK_DEFAULT_DIR` 只是默认工作目录，不是安全 allowlist。

`deployment_mode: auto` 下切换到 native 时，安装器会要求显式确认风险；确认文字以当前平台提示为准。如果需要“只能访问指定目录”，使用 Docker 模式。

## 安装过程会做什么

`install` 会自动：

- 识别 OS / CPU 架构；
- 下载匹配的 OpenAI `tunnel-client runtime-cloudflared` 到 `.runtime/bin/`；
- 生成 AgentDock 本地 Bearer Token；
- 根据 `deployment_mode` 选择 Docker 或 native；
- Windows 下可启动已有 Docker Desktop，或准备 WSL + Docker Engine；
- Docker 模式拉取 `ghcr.io/uvwt/agentdock:latest`；
- native 模式下载 AgentDock 官方二进制到 `.runtime/bin/`。

macOS / Linux 下载器会校验 SHA-256，并在校验及 `--version` 检查成功后替换二进制；下载失败不会覆盖原有版本。`help/status/stop/logs` 不触发下载，因此 GitHub 不可访问时仍可执行本地管理命令。

`config.yaml` 与 `.runtime/` 已加入 `.gitignore`；不要强制添加或分享其中的真实 Key。

## 常用命令

| 功能 | Windows | macOS / Linux |
|---|---|---|
| 安装 | `.\agentdock.cmd install` | `./agentdock install` |
| 启动 | `.\agentdock.cmd start` | `./agentdock start` |
| 应用配置 | `.\agentdock.cmd apply` | `./agentdock apply` |
| 状态 | `.\agentdock.cmd status` | `./agentdock status` |
| 日志 | `.\agentdock.cmd logs` | `./agentdock logs` |
| 重启 | `.\agentdock.cmd restart` | `./agentdock restart` |
| 停止 | `.\agentdock.cmd stop` | `./agentdock stop` |
| 更新组件 | `.\agentdock.cmd update` | `./agentdock update` |

`start` / `apply` 使用 Docker 后台模式启动，正常完成后会直接返回终端，不需要手工选择 `d Detach`。

## 项目结构

```text
.
├── README.md
├── config.example.yaml
├── agentdock.cmd
├── agentdock
├── scripts/
│   ├── bootstrap-tunnel.ps1
│   ├── bootstrap-tunnel.sh
│   ├── download-release.py
│   ├── windows.ps1
│   └── agentdock.sh
├── docs/
│   ├── images/
│   └── macos-install.md
├── tests/
└── .runtime/
```

上游项目：

- AgentDock: <https://github.com/uvwt/agentdock>
- OpenAI tunnel-client: <https://github.com/openai/tunnel-client>
- OpenAI Tunnel 官方说明: <https://github.com/openai/tunnel-client/blob/master/docs/end-user-guide.md>
