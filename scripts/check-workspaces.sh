#!/usr/bin/env bash
# Validate workspace mount permissions for the WSL default user.
# Input: TAB-separated <access mode><TAB><absolute path>. No eval, no shell interpolation.
set -euo pipefail
umask 077
failures=0
while IFS=$'\t' read -r mode path || [[ -n "${mode:-}${path:-}" ]]; do
  [[ -z "${mode:-}${path:-}" ]] && continue
  if [[ "$mode" != "rw" && "$mode" != "ro" ]]; then
    printf 'Invalid workspace mode\n' >&2
    exit 2
  fi
  if [[ "$path" != /* || "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then
    printf 'Invalid absolute workspace path\n' >&2
    exit 2
  fi
  if [[ ! -d "$path" || ! -r "$path" || ! -x "$path" ]]; then
    printf 'Workspace is inaccessible: %q\n' "$path" >&2
    failures=$((failures+1))
  elif [[ "$mode" == rw && ! -w "$path" ]]; then
    printf 'Read/write workspace is not writable: %q\n' "$path" >&2
    failures=$((failures+1))
  fi
done
if (( failures > 0 )); then
  printf '%s workspace(s) failed preflight.\n' "$failures" >&2
  exit 1
fi
printf 'Workspace preflight passed.\n'
