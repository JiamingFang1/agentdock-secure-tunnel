# Web manager status and startup

Goal: report verified workspace state on macOS/Linux and Windows, and open the
local manager after successful macOS startup.

Design: Docker status reads the running container environment. Native launches
save workspace name/path and process identity; status accepts the snapshot only
while that same process lives. Changing the configured name or path does not
change the snapshot. Old native processes without a snapshot remain unverified
until restarted. The manager displays service health separately from workspace
verification. Its launcher verifies readiness before opening a browser and reuses
the existing manager. Web-initiated actions suppress browser opening.

Execution: inline in the existing workspace, preserving user configuration.

- [x] Add failing regression tests for native snapshots, Docker inspection,
  workspace status parsing, and manager readiness/browser behavior.
- [x] Implement process-bound native snapshots and common CLI status labels;
  fix Windows native verification and exclude stopped containers.
- [x] Add idempotent manager startup on POSIX and suppress browser opening for
  actions launched from the manager. Show clear health and verification labels.
- [x] Run focused tests, full unittest discovery, shell syntax checks and local
  status/readiness checks. Document Windows runtime verification limitations.

Validation: `python3 -m unittest discover -s tests -q` ran 83 tests successfully
(17 Windows/PowerShell-only tests skipped). Shell and JS syntax checks and
`git diff --check` passed. Local native status verified `agentforge` / `YES`.
Playwright verified page identity, status and start actions, desktop and mobile
rendering, and zero console warnings/errors after reloading the new manager.
Browser plugin was unavailable, so the installed Playwright CLI was used.
Screenshots are in `/private/tmp/agentdock-manager-fixed.png` and
`/private/tmp/agentdock-manager-mobile.png`. Windows runtime execution remains
unverified on this macOS host. Docker verification checks the default workspace
name; it does not certify all mount settings or other configuration fields.
