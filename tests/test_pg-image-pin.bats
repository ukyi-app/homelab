#!/usr/bin/env bats
# PG 이미지 핀 정합 가드(M6) — SSOT는 platform/cnpg/prod/cluster.yaml spec.imageName.
# 인클러스터 소비자(basebackup-cronjob.yaml·restore-drill-script.sh)는 런타임에 레포가 없어
# 파생 불가 → 하드코딩을 허용하되 이 게이트가 SSOT 일치를 강제한다(PG 메이저 3-이미지 동시
# 갱신 함정 클래스 — PgDumpHedgeStale #178 낙진과 동일 계열). dr-drill.sh는 파생이라 리터럴 0.
# 신규 하드코딩 소비자는 git grep 스코프(전 레포)로 자동 편입된다.

PIN_RE='ghcr\.io/cloudnative-pg/postgresql:[0-9][A-Za-z0-9._-]*'
SSOT_FILE=platform/cnpg/prod/cluster.yaml

@test "cluster.yaml exposes exactly one PG image pin (SSOT sanity)" {
  # ⚠️ 옛 판정은 이름이 약속한 둘 중 어느 것도 재지 않았다. ① 파이프 마지막이 `sort`라 `$status`는
  #    grep의 rc(1=0건 / 2=파일 부재)와 무관하게 항상 0이고, ② `echo "$output" | wc -l`은 빈
  #    문자열에도 개행 한 줄을 내 **0건을 1로** 읽었다. 실측: SSOT 파일을 치워도, imageName 줄을
  #    지워도 이 레인은 초록이었다(red가 되는 유일한 조건이 핀 2건 이상). 「열거 붕괴 → vacuous
  #    green」②의 교과서적 형태다. `grep -c .`는 빈 입력에 0을 낸다.
  [ -f "$SSOT_FILE" ]
  run bash -c "grep -Eo '$PIN_RE' $SSOT_FILE | LC_ALL=C sort -u"
  [ "$(printf '%s' "$output" | grep -c .)" -eq 1 ]
}

@test "all hardcoded PG image pins repo-wide match the cluster.yaml SSOT" {
  ssot="$(grep -Eo "$PIN_RE" "$SSOT_FILE" | LC_ALL=C sort -u)"
  [ -n "$ssot" ]
  # 전 레포의 리터럴 핀은 SSOT와 동일해야 한다
  run bash -c "git grep -h -Eo '$PIN_RE' | LC_ALL=C sort -u"
  [ "$status" -eq 0 ]
  [ "$output" = "$ssot" ]
}
