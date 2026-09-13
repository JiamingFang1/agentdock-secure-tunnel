# AgentDock Secure Tunnel

让 **AgentDock 运行在隔离的 Docker 容器中**，再通过 **OpenAI Secure MCP Tunnel** 接入 ChatGPT。

```text
ChatGPT
  ↓
OpenAI Secure MCP Tunnel
  ↓
tunnel-client（宿主机）
  ↓
127.0.0.1:<port>
  ↓
AgentDock（Docker）
  ↓
仅挂载指定 workspace
```

支持：Windows、macOS、Linux，amd64 / arm64。

> `tunnel-client` 始终运行在宿主机。OpenAI Runtime API Key 不会注入 AgentDock 容器。

## 1. 创建 OpenAI Tunnel

打开：<https://platform.openai.com/settings/organization/tunnels>

1. 点击 **Create tunnel**。
2. 填写名称、描述。
3. 选择准备在 ChatGPT 中使用的 Organization / Workspace。
4. 创建后复制 Tunnel ID。

![Tunnel 创建界面示意](docs/images/tunnel-create.svg)

本地 `tunnel-client` 与 ChatGPT Connector 必须使用同一个 Tunnel ID。

## 2. 创建 Runtime API Key

打开：<https://platform.openai.com/settings/organization/api-keys>

创建 **Restricted Runtime API Key**。运行 Tunnel 的用户/角色至少需要：

```text
Tunnels: Read
Tunnels: Use
```

不要给长期运行的 `tunnel-client` 使用 Admin API Key。

![Tunnel 权限界面示意](docs/images/tunnel-permissions.svg)

OpenAI 官方说明：<https://github.com/openai/tunnel-client/blob/master/docs/end-user-guide.md>

## 3. 安装前置依赖

需要两个组件：

- Docker Engine + Docker Compose
- OpenAI `tunnel-client`

`tunnel-client` 下载：<https://github.com/openai/tunnel-client/releases/latest>

选择与你系统匹配的 `runtime-cloudflared` 包，并确保：

```text
tunnel-client --version
```

可以直接执行。

### Windows

优先使用 Docker Desktop。如果机器不能安装 Docker Desktop，可以使用：

```text
Windows PowerShell
   ↓
WSL2 Ubuntu / Debian
   ↓
Docker Engine
   ↓
AgentDock Container
```

Docker Engine 官方安装：

- Ubuntu: <https://docs.docker.com/engine/install/ubuntu/>
- Debian: <https://docs.docker.com/engine/install/debian/>

安装后在 Windows PowerShell 验证：

```powershell
wsl -u root -- docker info
wsl -u root -- docker compose version
```

本项目会自动优先检测 Windows Docker；不可用时自动检测 WSL Docker Engine。

### macOS

可以使用 Docker Desktop，也可以使用更轻量的 Colima：

```bash
brew install docker docker-compose colima
colima start
```

### Linux

使用原生 Docker Engine + Compose Plugin。Ubuntu / Debian 可直接参考上面的 Docker 官方安装文档。

## 4. 配置

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

只修改四项：

```yaml
tunnel_id: 'TUNNEL_ID_HERE'
runtime_api_key: 'RUNTIME_API_KEY_HERE'
agentdock_port: 18765
workspace_path: 'D:\Projects\VisionAgent'
```

目录示例：

```text
Windows : D:\Projects\VisionAgent
macOS   : /Users/you/Projects/VisionAgent
Linux   : /home/you/projects/VisionAgent
```

`config.yaml` 与 `.runtime/` 已加入 `.gitignore`，不会提交真实 Key。

## 5. 安装

Windows：

```powershell
.\agentdock.cmd install
```

macOS / Linux：

```bash
./agentdock install
```

`install` 会：

- 检查 Docker / Compose；
- 检查 `tunnel-client`；
- 生成 AgentDock 本地 Bearer Token；
- 生成 Docker Compose 与 Tunnel Profile；
- 拉取官方 AgentDock 镜像。

它不会自动修改系统或安装 Docker。

## 6. 启动

Windows：

```powershell
.\agentdock.cmd start
```

macOS / Linux：

```bash
./agentdock start
```

常用命令：

| 功能 | Windows | macOS / Linux |
|---|---|---|
| 状态 | `.\agentdock.cmd status` | `./agentdock status` |
| 日志 | `.\agentdock.cmd logs` | `./agentdock logs` |
| 重启 | `.\agentdock.cmd restart` | `./agentdock restart` |
| 停止 | `.\agentdock.cmd stop` | `./agentdock stop` |
| 更新 AgentDock 镜像 | `.\agentdock.cmd update` | `./agentdock update` |

正常状态：

```text
AgentDock : RUNNING
Tunnel    : RUNNING
MCP       : http://127.0.0.1:18765/mcp
```

## 7. ChatGPT 网页端配置

保持 AgentDock 与 `tunnel-client` 运行，然后打开：

<https://chatgpt.com/#settings/Connectors>

1. 新建 Custom MCP / App Connection。
2. **Connection** 选择 **Tunnel**。
3. 选择刚才创建的 Tunnel，或填写相同的 Tunnel ID。
4. 不要把 AgentDock 本地 Bearer Token 填进 ChatGPT；它由本机 `tunnel-client` 自动注入。
5. 如果页面显示 Authentication 选项，并允许无认证 Connector，选择 **None / No authentication**。AgentDock 自己的认证只发生在 `tunnel-client → AgentDock` 这一跳。

![ChatGPT Tunnel Connector 示意](docs/images/chatgpt-tunnel.svg)

如果看不到 Tunnel，优先检查：

- Tunnel 是否绑定正确 Workspace；
- 当前用户是否具有 **Tunnels Read + Use**；
- `status` 是否显示 AgentDock 和 Tunnel 都在运行；
- Tunnel 是否刚创建、仍在同步。

## 安全边界

```text
宿主机
├── tunnel-client
│   └── OpenAI Runtime API Key
│
└── Docker Container
    ├── AgentDock
    ├── 本地 AgentDock Bearer Token
    └── 一个 workspace bind mount
```

AgentDock 容器只得到：

- `workspace_path`；
- 独立 AgentDock 状态卷；
- 自动生成的本地 Bearer Token。

不会得到 OpenAI Runtime API Key。

不要挂载：

- 整个用户 Home；
- 整块系统盘；
- Docker Socket；
- 与项目无关的密钥目录。

需要注意：这里限制的是 **AgentDock 能看到哪些宿主机目录**。它仍然可以访问容器自己的 Linux 文件系统。

### Linux 写权限

官方 AgentDock 容器默认使用 UID/GID `10001`。如果 Linux 上只能读不能写 workspace，可使用 ACL 授权：

```bash
sudo setfacl -R -m u:10001:rwX /path/to/workspace
sudo find /path/to/workspace -type d -exec setfacl -m d:u:10001:rwX {} +
```

## 项目结构

```text
.
├── README.md
├── config.example.yaml
├── agentdock.cmd              # Windows 统一入口
├── agentdock                  # macOS / Linux 统一入口
├── scripts/
│   ├── agentdock.ps1
│   └── agentdock.sh
├── docs/images/
└── .runtime/                  # 本机自动生成，不提交 Git
```

上游项目：

- AgentDock: <https://github.com/uvwt/agentdock>
- OpenAI tunnel-client: <https://github.com/openai/tunnel-client>
