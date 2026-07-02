#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; F="$ROOT/platform/argocd/root/appset.yaml"; }

@test "appset.yaml is valid yaml" {
  run yq e 'true' "$F"
  [ "$status" -eq 0 ]
}
@test "appset.yaml has exactly two ApplicationSets" {
  run bash -c "grep -c '^kind: ApplicationSet' '$F'"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}
@test "appset source paths are unchanged after comment edit" {
  run grep -c "apps/\*/deploy/prod" "$F"
  [ "$status" -eq 0 ]
}

@test "telegram-notify subscription label is wired on apps appset, platform templatePatch, and cnpg-data" {
  has() { printf '%s' "$1" | grep -qF "$2" || { echo "miss: $2"; false; }; }
  C="$ROOT/platform/argocd/root/apps/cnpg-data.yaml"
  # apps appset: 모든 앱에 정적 라벨
  run yq 'select(.kind=="ApplicationSet" and .metadata.name=="apps") | .spec.template.metadata.labels."notify.homelab/telegram"' "$F"
  [ "$output" = "true" ] || { echo "apps label=$output"; false; }
  # cnpg-data 수동 Application: 정적 라벨(appset exclude라 직접)
  run yq '.metadata.labels."notify.homelab/telegram"' "$C"
  [ "$output" = "true" ] || { echo "cnpg-data label=$output"; false; }
  # platform-components: data-conn/cache만 templatePatch 조건부(missingkey=error 안전 — inline .X 금지)
  run yq 'select(.kind=="ApplicationSet" and .metadata.name=="platform-components") | .spec.templatePatch' "$F"
  has "$output" 'data-conn'; has "$output" 'cache'; has "$output" 'files'; has "$output" 'notify.homelab/telegram'
}
