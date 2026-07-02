#!/usr/bin/env bats
# PG 이미지 핀 정합 가드(M6) — SSOT는 platform/cnpg/prod/cluster.yaml spec.imageName.
# 인클러스터 소비자(basebackup-cronjob.yaml·restore-drill-script.sh)는 런타임에 레포가 없어
# 파생 불가 → 하드코딩을 허용하되 이 게이트가 SSOT 일치를 강제한다(PG 메이저 3-이미지 동시
# 갱신 함정 클래스 — PgDumpHedgeStale #178 낙진과 동일 계열). dr-drill.sh는 파생이라 리터럴 0.
# 신규 하드코딩 소비자는 git grep 스코프(docs/plans 제외 전 레포)로 자동 편입된다.

PIN_RE='ghcr\.io/cloudnative-pg/postgresql:[0-9][A-Za-z0-9._-]*'
SSOT_FILE=platform/cnpg/prod/cluster.yaml

@test "cluster.yaml exposes exactly one PG image pin (SSOT sanity)" {
  run bash -c "grep -Eo '$PIN_RE' $SSOT_FILE | sort -u"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "all hardcoded PG image pins repo-wide match the cluster.yaml SSOT" {
  ssot="$(grep -Eo "$PIN_RE" "$SSOT_FILE" | sort -u)"
  [ -n "$ssot" ]
  # docs/plans는 역사 기록(구버전 핀 잔존)이라 제외 — 그 외 전 레포의 리터럴 핀은 SSOT와 동일해야 한다
  run bash -c "git grep -h -Eo '$PIN_RE' -- ':(exclude)docs/plans' | sort -u"
  [ "$status" -eq 0 ]
  [ "$output" = "$ssot" ]
}
