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

@test "both ApplicationSet templates carry a retry policy (cold-start CRD ordering has no other backstop)" {
  # ⚠️ appset이 만드는 Application끼리는 sync-wave 관계가 아예 없다(ApplicationSet 컨트롤러가 직접
  #    만들어 root app-of-apps의 sync 대상이 아니다). 그래서 Gateway API CRD를 소유한 traefik-prod보다
  #    소비자(HTTPRoute)가 먼저 도달할 수 있고, dry-run이 `resource mapping not found`로 죽으면
  #    그 Application의 리소스가 하나도 apply되지 않는다. auto-sync는 같은 revision의 실패를
  #    재시도하지 않고 selfHeal은 성공 이후에만 걸리므로 retry가 유일한 자가복구 경로다.
  #    (2026-08-14 NUC 콜드스타트 실측: 5개 앱이 이 상태로 Missing에 고착했다.)
  for n in platform-components apps; do
    run yq "select(.kind==\"ApplicationSet\" and .metadata.name==\"$n\") | .spec.template.spec.syncPolicy.retry.limit" "$F"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qxF -- '5' || { echo "$n: retry.limit=$output (기대 5)"; false; }
    run yq "select(.kind==\"ApplicationSet\" and .metadata.name==\"$n\") | .spec.template.spec.syncPolicy.retry.backoff.duration" "$F"
    printf '%s' "$output" | grep -qxF -- '15s' || { echo "$n: retry.backoff.duration=$output (기대 15s)"; false; }
    run yq "select(.kind==\"ApplicationSet\" and .metadata.name==\"$n\") | .spec.template.spec.syncPolicy.retry.backoff.maxDuration" "$F"
    printf '%s' "$output" | grep -qxF -- '5m' || { echo "$n: retry.backoff.maxDuration=$output (기대 5m)"; false; }
  done
}

@test "telegram-notify subscription label is wired on apps appset, platform templatePatch, and cnpg-data" {
  has() { printf '%s' "$1" | grep -qF -- "$2" || { echo "miss: $2"; false; }; }
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
