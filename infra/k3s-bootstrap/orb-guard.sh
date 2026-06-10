#!/usr/bin/env bash
# R3 health check: assert the OrbStack environment holds EXACTLY ONE machine,
# named "$ORB_MACHINE", in the running state. The OrbStack memory cap is GLOBAL,
# so any extra machine/container silently steals from the k3s VM's 11 GiB.
# Re-used as a gate by later milestones — keep it dependency-free (no jq).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
ORB_MACHINE="${ORB_MACHINE:-k3s}"

if ! command -v orb >/dev/null 2>&1; then
  echo "FAIL: 'orb' not found on PATH — is OrbStack installed?" >&2
  exit 2
fi

# `orb list` (OrbStack 2.x) prints NO header when piped/non-TTY; in a TTY it may
# print a "NAME …" header. Robust to both: drop blank lines and any header row.
mapfile -t rows < <(orb list 2>/dev/null | awk 'NF && $1 != "NAME"')

count="${#rows[@]}"
if [ "$count" -ne 1 ]; then
  echo "FAIL: expected exactly one OrbStack machine, found ${count} (R3 global-cap rule)." >&2
  printf '  %s\n' "${rows[@]}" >&2
  exit 1
fi

name="$(awk '{print $1}' <<<"${rows[0]}")"
state="$(awk '{print $2}' <<<"${rows[0]}")"

if [ "$name" != "$ORB_MACHINE" ]; then
  echo "FAIL: the single machine is '${name}', expected '${ORB_MACHINE}'." >&2
  exit 1
fi
if [ "$state" != "running" ]; then
  echo "FAIL: machine '${name}' is '${state}', expected 'running'." >&2
  exit 1
fi

echo "OK: exactly one OrbStack machine '${name}' is running."
