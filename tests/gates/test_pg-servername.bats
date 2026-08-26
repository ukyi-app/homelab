#!/usr/bin/env bats
# CNPG 아카이브 serverName 분리 가드(scripts/check-pg-servername.sh)의 계약.
# ⚠️ 픽스처로 검사한다 — 레포의 현재 값에 의존하면 owner가 컷오버에서 값을 바꾸는 순간 조용히
#    뒤집힌다(이 세션에서 test_07이 정확히 그렇게 깨졌다).
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  sh="$ROOT/scripts/check-pg-servername.sh"
  FX="$BATS_TEST_TMPDIR/cluster.yaml"
}
# $1=쓰기 serverName, $2=읽기 serverName(빈 문자열이면 externalClusters 없음 = main의 initdb 형태)
_fx() {
  { printf 'apiVersion: postgresql.cnpg.io/v1\nkind: Cluster\nspec:\n  plugins:\n'
    printf '    - name: barman-cloud.cloudnative-pg.io\n      isWALArchiver: true\n'
    printf '      parameters: { barmanObjectName: pg-r2, serverName: %s }\n' "$1"
    if [ -n "${2:-}" ]; then
      printf '  externalClusters:\n    - name: pg-mac\n      plugin:\n'
      printf '        name: barman-cloud.cloudnative-pg.io\n'
      printf '        parameters: { barmanObjectName: pg-r2, serverName: %s }\n' "$2"
    fi
  } > "$FX"
}
run_g() { PG_CLUSTER_YAML="$FX" run bash "$sh"; }

@test "guard exists, is executable, and passes shellcheck" {
  [ -x "$sh" ]
  # 소스하는 lib을 입력에 함께 넘긴다 — 단일 파일 호출은 source 해석이 안 돼 SC1091(info)로
  # rc 1이 난다(게이트의 전 파일 일괄 호출과 동등한 형태로 맞춘다).
  run shellcheck "$sh" "$ROOT/scripts/lib/guard.sh" "$ROOT/scripts/lib/scan-floor.sh"
  [ "$status" -eq 0 ]
}

@test "(A) passes when write and read serverName differ (migration-branch shape)" {
  _fx pg-nuc pg
  run_g
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- '분리됨'
}

@test "(A) passes with no externalClusters at all (main's initdb shape)" {
  _fx pg ''
  run_g
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- '복구 원본 없음'
}

@test "(A) REJECTS write == read (both primaries would archive to one prefix)" {
  _fx pg pg
  run_g
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '쓰기와 읽기 serverName이 같다'
}

@test "(A) fails closed when the write serverName cannot be enumerated (0 hits is not 'separated')" {
  printf 'apiVersion: postgresql.cnpg.io/v1\nkind: Cluster\nspec:\n  plugins: []\n' > "$FX"
  run_g
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '쓰기 serverName을 찾지 못했다'
}

@test "(A) fails closed when externalClusters exist but carry no serverName" {
  { printf 'apiVersion: postgresql.cnpg.io/v1\nkind: Cluster\nspec:\n  plugins:\n'
    printf '    - name: barman-cloud.cloudnative-pg.io\n      parameters: { serverName: pg-nuc }\n'
    printf '  externalClusters:\n    - name: pg-mac\n      plugin: { name: barman-cloud.cloudnative-pg.io, parameters: { barmanObjectName: pg-r2 } }\n'
  } > "$FX"
  run_g
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '복구 원본의 serverName을 찾지 못했다'
}

@test "(B) is SKIPPED when EXPECT_PG_SERVERNAME is empty (branch gate must stay green)" {
  # 이 분리가 없으면 마이그레이션 브랜치의 gate가 영구 red가 된다 — check-argocd-revision과 같은 이유.
  _fx pg-nuc pg
  PG_CLUSTER_YAML="$FX" EXPECT_PG_SERVERNAME="" run bash "$sh"
  [ "$status" -eq 0 ]
  ! printf '%s' "$output" | grep -qF -- '고정='
}

@test "(B) BLOCKS the branch value from entering main while the live cluster expects pg" {
  # 실제 사고 경로: nuc-migration을 (targetRevision을 되돌린 형태로) Mac 생존 중 머지하면
  # Mac의 ArgoCD가 selfHeal로 라이브 Cluster의 아카이브를 pg-nuc로 갈아탄다.
  _fx pg-nuc pg
  PG_CLUSTER_YAML="$FX" EXPECT_PG_SERVERNAME=pg run bash "$sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- '기대값은'
}

@test "(B) passes when the value matches the expectation" {
  _fx pg ''
  PG_CLUSTER_YAML="$FX" EXPECT_PG_SERVERNAME=pg run bash "$sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- '고정=pg'
}

@test "the REAL repo cluster.yaml passes the (A) coherence check" {
  # 픽스처만 보면 실 파일이 깨져도 초록이다 — 실 파일도 한 번 통과시킨다(값은 단언하지 않는다).
  run bash "$sh"
  [ "$status" -eq 0 ]
}
