#!/usr/bin/env bats
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
f=platform/cnpg/prod/object-store.yaml

@test "endpoint is R2 and region is auto" {
  grep -q 'endpointURL: .*\.r2\.cloudflarestorage\.com' "$f"
  grep -qE 'name:\s+AWS_REGION' "$f"
}
@test "creds come from the cnpg-r2-creds secret, not inline" {
  grep -q 'name: cnpg-r2-creds' "$f"
  run grep -E 'AWS_SECRET_ACCESS_KEY:\s+\S' "$f"
  [ "$status" -eq 1 ]
}
@test "offsite retention is 14 days" {
  grep -q 'retentionPolicy: "14d"' "$f"
}
@test "the ObjectStore name is the identity every consumer references" {
  # ⚠️ 이 이름 하나가 WAL archiver(cluster.yaml)·복원 drill(restore-drill-script.sh)·
  #    DR 드릴(scripts/dr-drill.sh)·아카이브 리셋(scripts/reset-pg-r2-archive.sh)을 함께 묶는다.
  #    한 곳만 개명하면 barman-cloud plugin이 "barman object configuration not found"로 무한
  #    requeue하고 pre-reconcile hook이 reconciliation을 멈춘다(object-store.yaml:7-15의
  #    2026-08-13 실측). 콜드스타트/DR에는 클러스터도 메트릭도 없어 알림 경로 자체가 없으므로
  #    개명 드리프트의 유일한 머지-전 증인이 여기다.
  # ⚠️ 값 비교는 형제 test_cluster_params.bats:71 관용구(값을 뽑아 `grep -qxF`)다 —
  #    `yq -e '… == "…"'`는 값이 false면 exit 1이라 '불일치'와 'yq 사망'이 같은 rc로 뭉개진다
  #    (docs/traps-detail.md 「yq -e는 값이 false면 exit 1」).
  n="$(yq -e '.metadata.name' "$f")"
  [ -n "$n" ] # 열거 붕괴 방지 — 빈 값은 '일치'가 아니라 '못 읽었다'는 뜻이다
  c="$(yq -e '.spec.plugins[] | select(.name == "barman-cloud.cloudnative-pg.io") | .parameters.barmanObjectName' platform/cnpg/prod/cluster.yaml)"
  printf '%s' "$c" | grep -qxF -- "$n"
  d=platform/cnpg/prod/restore-drill-script.sh
  [ -s "$d" ] # 피연산자 실재 앵커 — 파일이 사라지면 무매치가 아니라 read 실패로 red여야 한다
  grep -qF "barmanObjectName: $n" "$d"
  r=scripts/dr-drill.sh
  [ -s "$r" ]
  grep -qF "barmanObjectName: $n" "$r"
  a=scripts/reset-pg-r2-archive.sh
  [ -s "$a" ]
  grep -qxF "OBJSTORE=$n" "$a"
}
