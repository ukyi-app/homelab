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
  # 유일하게 빠져 있던 DR 생산자 — 복원 드릴 CronJob. 이 이름이 없으면 렌더 증인이 "백업 3종은
  # 있는데 복구 증명은 없다"를 초록으로 통과시킨다(배선의 머지-전 증인은 test_restore_drill.bats).
  echo "$output" | grep -q 'name: pg-restore-drill'
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
@test "data app is sync-wave -1, project platform, ns database" {
  f=platform/argocd/root/apps/cnpg-data.yaml
  grep -qE 'argocd.argoproj.io/sync-wave:\s*"-1"' "$f"
  grep -qE 'project:\s+platform' "$f"   # 테마1 권한경계 재배정(default→platform)
  grep -qE 'namespace:\s+database' "$f"
}
@test "database namespace is declared with PSA baseline labels (cnpg-data App owns it, wave -3)" {
  f=platform/cnpg/prod/namespace.yaml
  grep -qE 'pod-security.kubernetes.io/enforce:\s*baseline' "$f"   # pg/백업/덤프/복원드릴은 baseline-clean
  grep -qE 'pod-security.kubernetes.io/warn:\s*restricted' "$f"
  grep -qE 'argocd.argoproj.io/sync-wave:\s*"-3"' "$f"             # 시드(-2)·Cluster(-1)보다 먼저 라벨 적용
  grep -q 'namespace.yaml' platform/cnpg/prod/kustomization.yaml   # kustomization에 배선됨
}

# ── KSOPS 산출 Secret의 sync-wave (2026-08-13 NUC 첫 bootstrap 교착에서 나온 가드) ──────────
# ⚠️ **`generatorOptions`는 `generators:`(KSOPS exec plugin) 산출물에 적용되지 않는다.**
#    kustomize의 generatorOptions는 내장 generator(configMapGenerator/secretGenerator) 전용이다.
#    그래서 네 시드 Secret은 annotation 없이(= ArgoCD 기본 wave 0) 렌더됐고, Cluster(wave -1)가
#    자격 Secret보다 먼저 올라가 barman이 R2 자격을 못 얻었다 → recovery 실패 → Cluster가 영원히
#    Healthy 아님 → ArgoCD가 wave 0으로 넘어가지 않음 → **Secret이 영원히 apply되지 않는 교착**.
#    kustomization.yaml의 명시적 patch가 그 wave를 붙인다. 이 @test가 그 patch를 고정한다.
@test "KSOPS-generated seed Secrets carry a sync-wave earlier than the Cluster" {
  run bash -c 'kustomize build --enable-alpha-plugins --enable-exec platform/cnpg/prod'
  [ "$status" -eq 0 ]
  out="$output"
  # Cluster의 wave를 기준으로 삼는다(하드코딩하지 않는다 — 둘의 관계가 계약이다).
  # ⚠️ 문서 블록으로 나눠 읽는다 — 렌더 출력에서 `kind:`는 첫 줄이 아니고(apiVersion 다음),
  #    `name:`도 annotations 뒤에 온다. 줄 순서를 전제하면 조용히 빈 값을 집는다.
  cw="$(printf '%s' "$out" | awk 'BEGIN{RS="\n---\n"} index($0,"\nkind: Cluster\n")||index($0,"kind: Cluster\n")==1 { if (match($0,/sync-wave: "?-?[0-9]+/)) { t=substr($0,RSTART,RLENGTH); sub(/^sync-wave: "?/,"",t); print t; exit } }')"
  [ -n "$cw" ]
  bad=""
  for s in cnpg-r2-creds pg-app-credentials pg-admin-credentials restore-drill-alerting; do
    # 해당 Secret 문서 블록만 떼어 wave를 읽는다(이름은 index로 정확 매치).
    w="$(printf '%s' "$out" | awk -v n="$s" 'BEGIN{RS="\n---\n"} (index($0,"\nkind: Secret\n")||index($0,"kind: Secret\n")==1) && index($0,"\n  name: " n "\n"){ if (match($0,/sync-wave: "?-?[0-9]+/)) { t=substr($0,RSTART,RLENGTH); sub(/^sync-wave: "?/,"",t); print t } }')"
    [ -n "$w" ] || { bad="$bad $s(wave없음)"; continue; }
    [ "$w" -lt "$cw" ] || bad="$bad $s(wave=$w>=Cluster$cw)"
  done
  [ -z "$bad" ]   # 비어야 통과. 디버깅: echo "$bad"
}
