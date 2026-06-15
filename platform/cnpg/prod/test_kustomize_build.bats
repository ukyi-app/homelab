#!/usr/bin/env bats
# 참고: kustomize-build 케이스들은 M2 시드(r2-creds.enc.yaml, app-credentials.enc.yaml)의
# 존재에 의존한다 — M2의 seed-secrets.sh 실행 이후에만 통과한다.
# 마지막 케이스(data 앱 배선)는 언제나 오프라인 검증 가능.

@test "kustomize build with ksops renders Cluster + ObjectStore + Pooler + backups" {
  run bash -c 'kustomize build --enable-alpha-plugins --enable-exec platform/cnpg/prod'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'kind: Cluster'
  echo "$output" | grep -q 'kind: ObjectStore'
  echo "$output" | grep -q 'kind: Pooler'
  echo "$output" | grep -q 'kind: ScheduledBackup'
  echo "$output" | grep -q 'name: cnpg-local-basebackup'
  echo "$output" | grep -q 'name: pg-dump-hedge-r2'
}
@test "all THREE database-ns seeds render as Secrets via KSOPS (none silently missing)" {
  run bash -c 'kustomize build --enable-alpha-plugins --enable-exec platform/cnpg/prod'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'name: cnpg-r2-creds'
  echo "$output" | grep -q 'name: pg-app-credentials'
  echo "$output" | grep -q 'name: restore-drill-alerting'
  echo "$output" | grep -q 'AWS_ACCESS_KEY_ID' # 정식 R2 스키마 (object-store.yaml과 일치)
  echo "$output" | grep -q 'TELEGRAM_BOT_TOKEN'
}
@test "restore-drill ConfigMap is GENERATED from the script (real recovery logic, not an empty placeholder)" {
  drill="$(kustomize build --enable-alpha-plugins --enable-exec platform/cnpg/prod \
    | yq 'select(.kind=="ConfigMap" and .metadata.name=="restore-drill-script") | .data."drill.sh"')"
  echo "$drill" | grep -q 'bootstrap:' # 복구 클러스터 로직 존재...
  echo "$drill" | grep -q 'recovery:'
  echo "$drill" | grep -q 'EXPECTED_ROWS'
  echo "$drill" | grep -q 'ACTUAL_ROWS'
  [ "$(printf '%s' "$drill" | wc -l)" -gt 30 ] # ...그리고 한 줄짜리 스텁이 아닌 전체 스크립트다
}
@test "data app is sync-wave -1, project default, ns database" {
  f=platform/argocd/root/apps/cnpg-data.yaml
  grep -qE 'argocd.argoproj.io/sync-wave:\s*"-1"' "$f"
  grep -qE 'project:\s+default' "$f"
  grep -qE 'namespace:\s+database' "$f"
}
@test "database namespace is declared with PSA baseline labels (cnpg-data App owns it, wave -3)" {
  f=platform/cnpg/prod/namespace.yaml
  grep -qE 'pod-security.kubernetes.io/enforce:\s*baseline' "$f"   # pg/백업/덤프/복원드릴은 baseline-clean
  grep -qE 'pod-security.kubernetes.io/warn:\s*restricted' "$f"
  grep -qE 'argocd.argoproj.io/sync-wave:\s*"-3"' "$f"             # 시드(-2)·Cluster(-1)보다 먼저 라벨 적용
  grep -q 'namespace.yaml' platform/cnpg/prod/kustomization.yaml   # kustomization에 배선됨
}
