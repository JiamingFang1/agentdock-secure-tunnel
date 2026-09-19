#!/bin/sh
# Run in the foreground of a dedicated Windows wsl.exe session.
# No Docker socket, credentials, root privileges, or busy loop are required.
set -eu
[ "$#" -eq 2 ] || exit 64
lease=$1
marker=$2
[ -n "$marker" ] || exit 64
owns_lease() {
    [ -r "$lease" ] && [ "$(cat "$lease" 2>/dev/null)" = "$marker" ]
}
owns_lease || exit 65
printf 'READY %s\n' "$marker"
while owns_lease; do
    sleep 2
done
