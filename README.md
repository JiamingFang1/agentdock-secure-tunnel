# AgentDock Secure Tunnel

Run AgentDock inside an isolated Docker container and connect it to ChatGPT through OpenAI Secure MCP Tunnel.

```text
ChatGPT -> OpenAI Secure MCP Tunnel -> tunnel-client (host) -> AgentDock (Docker) -> mounted workspace
```

Supported hosts:
- Windows 10/11: Docker Desktop, or WSL2 + Docker Engine when Docker Desktop is unavailable
- macOS: Docker Desktop or Colima
- Linux: Docker Engine
- amd64 and arm64

`tunnel-client` runs on the host. The OpenAI Runtime API Key is not injected into the AgentDock container.

## 1. Create an OpenAI Tunnel

Open <https://platform.openai.com/settings/organization/tunnels>.

1. Click **Create tunnel**.
2. Enter a name and description.
3. Select the Organization / Workspace used by ChatGPT.
4. Create it and copy the ID beginning with `tunnel_`.

![Tunnel creation UI](docs/images/tunnel-create.svg)

The local runtime and ChatGPT connector must use the same Tunnel ID.

## 2. Create the Runtime API Key

Open <https://platform.openai.com/settings/organization/api-keys>.

Create a **Restricted Runtime API Key** for the long-running `tunnel-client`. The user/role running it needs:

```text
Tunnels: Read
Tunnels: Use
```

Do not use an Admin API Key for the long-running tunnel daemon.

![Tunnel permission UI](docs/images/tunnel-permissions.svg)

OpenAI reference: <https://github.com/openai/tunnel-client/blob/master/docs/end-user-guide.md>

## 3. Configure

```bash
git clone https://github.com/JiamingFang1/agentdock-secure-tunnel.git
cd agentdock-secure-tunnel
```

Windows:

```powershell
Copy-Item config.example.yaml config.yaml
```

macOS / Linux:

```bash
cp config.example.yaml config.yaml
```

Edit these four values:

```yaml
tunnel_id: 'TUNNEL_ID_HERE'
runtime_api_key: 'RUNTIME_API_KEY_HERE'
agentdock_port: 18765
workspace_path: 'D:\Projects\VisionAgent'
```

Workspace examples:

```text
Windows : D:\Projects\VisionAgent
macOS   : /Users/you/Projects/VisionAgent
Linux   : /home/you/projects/VisionAgent
```

`config.yaml` and `.runtime/` are ignored by Git.

## 4. Install

Windows:

```powershell
.\agentdock.cmd install
```

The Windows installer prefers a working Windows Docker runtime. If unavailable, it can use WSL2 Ubuntu/Debian + Docker Engine.

macOS / Linux:

```bash
./agentdock install
```

On macOS, an existing Docker runtime is used first. If none is found and Homebrew is installed, the script installs Docker CLI + Compose + Colima.

On Ubuntu/Debian Linux, Docker Engine can be installed automatically when missing. Other distributions are supported when Docker Engine is already installed.

## 5. Start

Windows:

```powershell
.\agentdock.cmd start
```

macOS / Linux:

```bash
./agentdock start
```

| Action | Windows | macOS / Linux |
|---|---|---|
| Status | `.\agentdock.cmd status` | `./agentdock status` |
| Logs | `.\agentdock.cmd logs` | `./agentdock logs` |
| Restart | `.\agentdock.cmd restart` | `./agentdock restart` |
| Stop | `.\agentdock.cmd stop` | `./agentdock stop` |
| Update | `.\agentdock.cmd update` | `./agentdock update` |

Healthy status:

```text
AgentDock : RUNNING
Tunnel    : RUNNING
MCP       : http://127.0.0.1:18765/mcp
```

## 6. Add it to ChatGPT

Open <https://chatgpt.com/#settings/Connectors> while AgentDock and `tunnel-client` are running.

1. Set **Connection** to **Tunnel**.
2. Select the Tunnel you created, or paste its `tunnel_id`.
3. Do not put the AgentDock local Bearer Token into ChatGPT; this project injects it locally through `tunnel-client`.
4. If an Authentication selector is shown, use the no-auth option for the connector itself when your workspace allows it. AgentDock's private local authentication is handled between `tunnel-client` and the container.

![ChatGPT Tunnel connector UI](docs/images/chatgpt-tunnel.svg)

If the Tunnel does not appear, check the Workspace scope, Tunnels Read + Use permission, local status, and whether a newly created Tunnel is still propagating.

## Security model

```text
Host
├── tunnel-client
│   └── OpenAI Runtime API Key
└── Docker container
    ├── AgentDock
    ├── local AgentDock Bearer Token
    └── one mounted workspace
```

The container receives the selected workspace, a private AgentDock state volume, and a locally generated AgentDock Bearer Token. It does not receive the OpenAI Runtime API Key.

Do not mount your whole home directory, an entire system disk, Docker socket, or unrelated secret directories.

The workspace mount is a host-resource boundary, not a claim that AgentDock can see only one directory inside the container. AgentDock can still access its own container filesystem; host directories that were not mounted are not exposed by default.

### Native Linux write permission

The official AgentDock container runs as UID/GID `10001`. If it can read but cannot edit a native Linux workspace, grant UID 10001 write access, for example with ACL:

```bash
sudo setfacl -R -m u:10001:rwX /path/to/workspace
sudo find /path/to/workspace -type d -exec setfacl -m d:u:10001:rwX {} +
```

## Project layout

```text
.
├── README.md
├── config.example.yaml
├── agentdock.cmd
├── agentdock
├── scripts/
│   ├── agentdock.ps1
│   └── agentdock.sh
├── docs/images/
└── .runtime/
```

The scripts download the latest public `tunnel-client` runtime build and use `ghcr.io/uvwt/agentdock:latest`.

Upstream:
- <https://github.com/uvwt/agentdock>
- <https://github.com/openai/tunnel-client>
