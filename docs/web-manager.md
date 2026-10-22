# Web Manager (Windows)

The optional management interface is available at **http://127.0.0.1:18880/**.
Launch it with `agentdock-web.cmd` or start AgentDock using `agentdock.cmd start`.
Python 3.8+ is required. If Python is missing, the service CLI continues working.

## Capabilities

- See configured workspace names and access modes.
- Choose a read/write default workspace. This changes only `default_workspace` in ignored `config.yaml`.
- Invoke a fixed set of commands: `start`, `stop`, `restart`, `apply`, and `status`.
- After choosing a workspace, run **apply** to restart with the updated configuration.

## Security boundary

The web service listens on loopback only, port 18880. It does not expose logs,
API keys, arbitrary command execution, shell arguments, or filesystem browsing.
It requires a randomly generated HttpOnly SameSite=Strict session cookie and
checks the Origin header for every POST request. POST actions are allowlisted.
It does not publish management endpoints through the secure tunnel.

**Security note:** any local process with access to the current Windows account
could still attempt to interact with the browser or local service. Do not
forward port 18880 outside the host. Review your OS account and local access
policies before enabling the interface.

Configuration updates are saved atomically; no token fields are returned to the
browser. The service never prints command output, as output could contain secrets.

Troubleshooting: check that Python 3 is available, port 18880 is free,
and `config.yaml` exists. Use `agentdock.cmd status` for detailed diagnostics.
