#!/usr/bin/env bats
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
f=platform/cnpg/prod/object-store.yaml

@test "endpoint is R2 and region is auto" {
  # ⚠️ 계정 id까지 고정한다 — 예전 와일드카드(`.*\.r2\.cloudflarestorage\.com`)는 **다른 계정의**
  #    R2 엔드포인트를 그대로 통과시켰다. 이 축은 자격 실패로 WALArchiveStalled(15m)가 시끄럽게
  #    잡으므로 조용한 손실은 아니지만, 머지 전에 red가 나는 편이 값싸다.
  #    (계정 id의 IaC SSOT는 var.cloudflare_account_id인데 그 값은 gitignored tfvars에만 있어
  #     파생 대조가 불가능하다 — 그래서 destinationPath와 달리 여기만 리터럴 핀이다.)
  grep -qF 'endpointURL: "https://52f958915d71663164a60636dc2905ce.r2.cloudflarestorage.com"' "$f"
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
@test "the offsite destination bucket is the one terraform creates" {
  # ⚠️ 이 값이 물리 백업·WAL 아카이브의 목적지 루트다(serverName은 그 아래 prefix — 그쪽 절반은
  #    test_cluster_params.bats:71이 리터럴로 고정한다). **자격이 닿는 다른 실재 버킷**으로 바뀌면
  #    백업은 계속 '성공'하면서 런북·drill이 보는 위치와 어긋난다 — WALArchiveStalled도
  #    R2BackupStale도 안 뜨는 조용한 DR 손실이고, R2엔 버저닝이 없어(r2.tf) 되돌릴 수 없다.
  # 리터럴 재타이핑 대신 IaC 정본에서 파생한다(형제 test_pgdump_hedge.bats:69-74 관용구) —
  # 양쪽 드리프트를 동시에 문다. cluster.yaml:89 주석이 선언만 해 둔 등식의 실행판이다.
  tf=infra/cloudflare/r2.tf
  [ -s "$tf" ] # 피연산자 실재 앵커
  b="$(sed -n '/resource "cloudflare_r2_bucket" "pg_backups"/,/^}/s/^ *name *= *"\([^"]*\)".*/\1/p' "$tf")"
  [ -n "$b" ] # 열거 붕괴 방지 — 0건은 '일치'가 아니라 '못 읽었다'는 뜻이다
  d="$(yq -e '.spec.configuration.destinationPath' "$f")"
  printf '%s' "$d" | grep -qxF -- "s3://${b}/"
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
