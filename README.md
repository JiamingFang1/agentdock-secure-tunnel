# AgentDock Secure Tunnel

让 **AgentDock** 通过 **OpenAI Secure MCP Tunnel** 接入 ChatGPT。

默认推荐 Docker 隔离：

```text
ChatGPT → Secure MCP Tunnel → tunnel-client（宿主机） → AgentDock（Docker） → 指定 workspaces
```

也支持 native 宿主机部署，但 **native 模式没有容器目录隔离**。

支持 Windows、macOS、Linux，amd64 / arm64。

## 1. 创建 OpenAI Tunnel

打开：<https://platform.openai.com/settings/organization/tunnels>

1. 点击 **Create tunnel**。
2. 填写名称、描述等信息。
3. 创建完成后复制 Tunnel ID。
4. 后续本地 `config.yaml` 和 ChatGPT 端必须使用同一个 Tunnel。

![OpenAI Platform 创建 Tunnel](docs/images/image.png)

## 2. 创建 Runtime API Key

打开：<https://platform.openai.com/settings/organization/api-keys>

为长期运行的 `tunnel-client` 创建 **Restricted Runtime API Key**。

运行 Tunnel 的用户/角色至少需要：

```text
Tunnels: Read
Tunnels: Use
```

不要给长期运行的 `tunnel-client` 使用 Admin API Key。

![OpenAI Platform Runtime API Key / Tunnel 权限配置](docs/images/image2.png)

OpenAI 官方说明：<https://github.com/openai/tunnel-client/blob/master/docs/end-user-guide.md>

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

推荐配置：

```yaml
# auto = 优先使用 Docker；没有 Docker 时再询问是否使用 native
deployment_mode: 'auto'

# 第 1 步创建 Tunnel 后获得的 Tunnel ID
tunnel_id: 'TUNNEL_ID_HERE'

# 第 2 步创建的 Restricted Runtime API Key
# 不要提交真实 Key；config.yaml 已加入 .gitignore
runtime_api_key: 'RUNTIME_API_KEY_HERE'

# AgentDock 映射到宿主机的本地端口，一般保持默认即可
agentdock_port: 18765

# 默认工作区名称。
# 不写 name 时，工作区名称自动取 path 的最后一级目录名。
# 下面第一个 path 最后一级是 my-project，所以这里填写 my-project。
default_workspace: 'my-project'

workspaces:
  # WSL / Linux / macOS 目录示例
  # rw = AgentDock 可读写该目录
  - path: '/home/<user>/projects/my-project'
    mode: 'rw'

  # Windows 目录示例
  # Windows + WSL Docker 模式下会自动转换为 /mnt/d/workspace/shared-data
  - path: 'D:\workspace\shared-data'
    mode: 'rw'

  # 如需只读目录，可使用：
  # - path: 'D:\workspace\reference-docs'
  #   mode: 'ro'
```

> 把示例路径替换成你自己实际存在的目录即可。不要把密码、API Key 或其他敏感信息写进 workspace 路径或提交到 Git。

### workspace 名称规则

默认不需要写 `name`。

脚本会自动使用宿主目录最后一级作为 workspace 名称：

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

`default_workspace` 填自动推导出的目录名，例如：

```yaml
default_workspace: 'my-project'
```

则 AgentDock 的真实默认工作目录就是：

```text
/home/agentdock/AgentDock/workspaces/my-project
```

旧版配置中的 `name` 仍兼容，但新配置建议省略，直接使用目录最后一级名称。

### mode

```text
rw = 可读写
ro = 只读
```

默认 workspace 必须使用：

```yaml
mode: 'rw'
```

因为 AgentDock 启动时会对默认目录执行自己的权限保护逻辑。

### Docker 权限模型

Docker 模式会自动处理常见的 Linux / WSL UID/GID 权限问题：

- Linux / macOS：AgentDock 使用当前宿主用户的 UID/GID 运行；
- Windows + WSL Docker：AgentDock 使用默认 WSL 用户的 UID/GID 运行；
- AgentDock 自己的内部 volume 会由一次性 init 容器自动调整权限；
- 不会对所有 workspace 执行 `chown -R` 或 `chmod 777`。

Windows + WSL 下，启动前会检查：

```text
WSL Docker 是否可用
默认 WSL 用户 UID/GID
workspace 是否可读/可进入
rw workspace 是否可写
default_workspace 是否存在并为 rw
```

如果预检失败，`apply` 不会先停止当前正在运行的服务。

### Windows + WSL 混合目录

Windows 配置中可以同时写 Windows 原生路径和 WSL 路径：

```yaml
workspaces:
  - path: 'D:\workspace\windows-project'
    mode: 'rw'

  - path: '/home/<user>/projects/linux-project'
    mode: 'rw'
```

如果配置中存在 `/home/...` 这类 WSL 路径，Docker 模式会使用 **WSL Docker Engine**。

Windows 路径会自动转换：

```text
D:\workspace\windows-project
→ /mnt/d/workspace/windows-project
```

WSL 路径保持原样。

`config.yaml` 与 `.runtime/` 已加入 `.gitignore`，不会提交真实 Key。

## 4. 安装

Windows：

```powershell
.\agentdock.cmd install
```

macOS / Linux：

```bash
./agentdock install
```

`install` 会自动：

- 识别 OS / CPU 架构；
- 下载匹配的 OpenAI `tunnel-client runtime-cloudflared` 到 `.runtime/bin/`；
- 生成 AgentDock 本地 Bearer Token；
- 根据 `deployment_mode` 选择 Docker 或 native；
- Docker 模式拉取 `ghcr.io/uvwt/agentdock:latest`；
- native 模式下载 AgentDock 官方二进制到 `.runtime/bin/`。

### deployment_mode

```yaml
deployment_mode: 'auto'
```

可选：

```text
auto    优先 Docker；没有 Docker 时询问是否使用 native
docker  强制 Docker
native  直接宿主机运行 AgentDock
```

Docker 推荐用于目录隔离。没有 Docker 时，脚本会提醒先安装 Docker Engine；只有用户确认或明确设置 `native` 才使用宿主机部署。

## 5. 启动与应用配置

Windows：

```powershell
.\agentdock.cmd start
```

macOS / Linux：

```bash
./agentdock start
```

Docker 模式内部结构示例：

```text
/home/agentdock/AgentDock/
└── workspaces/
    ├── my-project
    └── shared-data
```

如果配置：

```yaml
default_workspace: 'my-project'
```

则：

```text
AGENTDOCK_DEFAULT_DIR=/home/agentdock/AgentDock/workspaces/my-project
```

也就是说 AgentDock 启动后的默认工作目录就是配置指定的 workspace，不再额外创建 `/default` 挂载。

### 修改配置后立即生效

修改 `default_workspace`、新增/删除 workspace、修改路径或 `ro/rw` 后执行：

Windows：

```powershell
.\agentdock.cmd apply
```

macOS / Linux：

```bash
./agentdock apply
```

`apply` 会先检查新配置是否可用；预检通过后，再重新生成容器配置并重启 AgentDock 和 Tunnel。

常用命令：

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

正常状态示例：

```text
AgentDock : RUNNING
Tunnel    : RUNNING
Mode      : docker-wsl
Default   : my-project -> /home/agentdock/AgentDock/workspaces/my-project
MCP       : http://127.0.0.1:18765/mcp
```

`start` / `apply` 使用 Docker 后台模式启动，正常完成后会直接返回终端，不需要再手工选择 `d Detach`。

## 6. ChatGPT 网页端配置

保持 AgentDock 与 `tunnel-client` 运行，然后在 ChatGPT 网页端打开 **Settings → Apps / Connectors**（具体名称可能随 UI 版本变化）。

1. 新建 Custom MCP / App Connection。
2. **Connection** 选择 **Tunnel**。
3. 选择前面在 OpenAI Platform 创建的同一个 Tunnel。
4. 不要把 AgentDock 本地 Bearer Token 填进 ChatGPT；它由本机 `tunnel-client` 自动注入到 AgentDock 请求。
5. 保存后让 ChatGPT 扫描并加载 AgentDock 暴露的 MCP tools。

![ChatGPT 网页端 Tunnel / MCP App 配置](docs/images/image3.png)

## Docker 与 native 的安全区别

### Docker

多个 workspace 只会把配置中列出的宿主机目录挂进容器：

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

native 模式没有挂载隔离，也无法强制执行 `ro/rw` workspace 权限。`default_workspace` 只决定 AgentDock 默认工作目录。

> native AgentDock 仍可能访问当前宿主机用户有权限访问的其他目录。

如果需要“只能接触指定目录”，使用 Docker 模式。

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
│   ├── windows.ps1
│   └── agentdock.sh
├── docs/images/
└── .runtime/
```

上游项目：

- AgentDock: <https://github.com/uvwt/agentdock>
- OpenAI tunnel-client: <https://github.com/openai/tunnel-client>
