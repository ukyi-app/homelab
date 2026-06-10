#!/usr/bin/env bash
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
for k in api worker ssr spa; do
  echo "== rendering kind=$k =="
  helm template t "$CHART" -f "$CHART/tests/fixtures/$k.yaml" \
    | kubeconform -strict -summary -ignore-missing-schemas \
        -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    || fail=1
done
exit $fail
