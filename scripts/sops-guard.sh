#!/usr/bin/env bash
set -euo pipefail
rc=0
for f in "$@"; do
  case "$f" in
    *.enc.yaml)
      if ! grep -q '^sops:' "$f" 2>/dev/null && ! grep -q 'sops_mac\|"sops":' "$f" 2>/dev/null; then
        echo "BLOCKED: $f is *.enc.yaml but NOT sops-encrypted (no sops metadata)." >&2
        echo "         Run: sops --encrypt --in-place \"$f\"" >&2
        rc=1
      fi
      ;;
  esac
done
exit $rc
