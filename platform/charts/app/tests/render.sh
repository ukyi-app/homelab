#!/usr/bin/env bash
set -euo pipefail
CHART="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$CHART/../../.." && pwd)"
REGO="$CHART/tests/psa-restricted.rego"
fail=0
for k in web worker site; do
  echo "== rendering kind=$k =="
  out="$(helm template t "$CHART" -f "$CHART/tests/fixtures/$k.yaml")"
  echo "$out" | kubeconform -strict -summary -ignore-missing-schemas \
        -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    || fail=1
  # PSA restricted 패리티(라이브 admission과 동일 기준) — 스키마가 못 잡는 약화를 렌더 파드에서 차단.
  echo "$out" | conftest test --policy "$REGO" - || fail=1
done
# 실제 앱 deploy values도 동일 conftest로 (적대 리뷰 Pass3 #3 — fixture만으론 앱 values 미커버).
# 인-레포 앱 0이면 glob 미매치 → no-op(첫 앱부터 강제 계약).
for vals in "$ROOT"/apps/*/deploy/prod/values.yaml; do
  [ -f "$vals" ] || continue
  app="$(echo "$vals" | sed -E 's#.*/apps/([^/]+)/.*#\1#')"
  echo "== rendering app=$app (deploy/prod values) =="
  helm template "$app" "$CHART" -f "$vals" | conftest test --policy "$REGO" - || fail=1
done
exit $fail
