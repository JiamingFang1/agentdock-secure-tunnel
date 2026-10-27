# Web Manager (macOS / Linux / Windows)

The optional management interface is available at **http://127.0.0.1:18880/**.
On macOS/Linux, `./agentdock start`, `restart`, and `apply` start or reuse the
manager and open the page after service startup. Browser opening is best effort;
headless hosts can use the printed URL. Set `AGENTDOCK_NO_BROWSER=1` to suppress
opening a browser. Actions invoked from the page never open another browser tab.
You can also run `python3 scripts/manage.py --ensure-running` independently.
On Windows, launch it with `agentdock-web.cmd` or `agentdock.cmd start` and visit
the URL manually.
Python 3.8+ is required. If Python is missing, the service CLI continues working.

## Capabilities

- See configured workspace names and access modes.
- Choose a read/write default workspace. This changes only `default_workspace` in ignored `config.yaml`.
- Invoke a fixed set of commands: `start`, `stop`, `restart`, `apply`, and `status`.
- After choosing a workspace, run **apply** to restart with the updated configuration.
- Service health is separate from workspace verification. `Config Applied: YES`
  means the running workspace matches the current configuration; `NO` means it
  differs or is stopped. `UNKNOWN` means the running workspace cannot be verified.
- Docker checks the running container's default directory. Native mode uses a
  workspace name/path snapshot bound to the process ID and start identity.
  Existing native processes from before this feature have no snapshot: restart
  once to establish it. Editing config or reusing a PID cannot relabel a process.

When upgrading an already running manager, stop its original Python process
(Ctrl+C if started in a terminal) and launch the manager again to load new code.
Refreshing the browser alone reloads static assets, not the Python backend.

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
