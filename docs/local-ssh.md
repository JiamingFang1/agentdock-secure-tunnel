# Optional WSL SSHFS workspace mounts

A remote folder can be exposed to the AgentDock Docker container by mounting it
with SSHFS inside the **default WSL distribution** and listing that WSL path as
a workspace in `config.yaml`. Use a distinct local mount point for each server.

1. Install SSHFS and configure SSH public-key access in WSL, without embedding
   private keys or passwords in this repository.
2. Mount the remote project directory into a WSL directory that is readable and
   traversable by the default WSL account; if configured as rw it must be writable.
3. Configure that absolute Linux path under `workspaces`.
4. Use `agentdock.cmd apply` to run workspace preflight before restarting.

For persistent setup, optionally create the ignored local script
`.runtime/wsl-before-compose.sh` with mount checks and SSHFS mount commands.
This script is executed with **WSL root privileges** during startup and apply.
Treat it as privileged configuration: restrict write access, keep credentials
out of it, and never run an untrusted script. It is *not* committed to GitHub.

The local hook has a 20-second execution limit. If it fails or times out,
startup continues to bounded per-workspace access checks; it cannot block
the entire service indefinitely. A missing, disconnected, or unresponsive
**non-default** workspace is reported as a warning and omitted from the generated
Docker Compose mounts for that run. The **default** workspace must still
be accessible and writable, otherwise startup fails clearly.

After restoring an optional SSHFS mount, run `agentdock.cmd apply` to
revalidate workspaces and include it in the container. An already-running
container will not gain the skipped mount automatically.

The mount's actual remote connectivity and read/write permission should be
tested independently before assuming a workspace is ready. Avoid multiple
simultaneous start/apply requests while diagnosing failed SSHFS mounts.
