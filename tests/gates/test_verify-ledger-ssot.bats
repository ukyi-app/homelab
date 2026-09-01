#!/usr/bin/env bats
# ledger 검증 파이프라인을 1곳(scripts/verify-ledger.sh)으로 수렴 — 인라인 conftest 3중 복제 제거.
# ⚠️ 중간 단언은 [ ]만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "verify-ledger.sh SSOT script exists and is executable" {
  [ -x "$ROOT/scripts/verify-ledger.sh" ]
  grep -q 'ledger-to-json.ts' "$ROOT/scripts/verify-ledger.sh"
  grep -q 'conftest test' "$ROOT/scripts/verify-ledger.sh"
}

@test "package.json verify:ledger delegates to the SSOT script" {
  run bun -e "process.stdout.write(require('$ROOT/package.json').scripts['verify:ledger'])"
  echo "$output" | grep -q 'scripts/verify-ledger.sh'
}

@test "Makefile verify target no longer inlines the conftest pipeline" {
  run grep -c 'conftest test /tmp/ledger.json' "$ROOT/Makefile"
  [ "$output" = "0" ]
  grep -q 'scripts/verify-ledger.sh' "$ROOT/Makefile"
}

# 마진 규약의 A′ 측정 서브쿼리 step이 cadvisor 스크레이프 간격을 넘으면 peak가 과소평가된다
# (docs/traps-detail.md 「원장 마진 규약의 서브쿼리 step이 …」). 2026-09-01 실측에서 `[14d:5m]`이
# 30초 스크레이프의 90%를 버려 repo-server peak를 60% 과소평가했고, 그 위에서 회수한 limit이
# 회귀가 됐다. 스크레이프 간격을 바꾸면서 원장 마커를 안 고치면 그 결함이 그대로 재발한다.
@test "ledger margin subquery step does not exceed the cadvisor scrape interval" {
  local cfg="$ROOT/platform/victoria-stack/prod/vmagent-scrape-config.yaml"
  [ -f "$cfg" ]

  # 선언된 모든 scrape_interval(글로벌 + job override) 중 최소값 — 초 단위
  local scrapes min_scrape
  scrapes="$(grep -oE 'scrape_interval:[[:space:]]*[0-9]+[sm]' "$cfg" | grep -oE '[0-9]+[sm]$')"
  [ -n "$scrapes" ]
  min_scrape=""
  local v n u
  while read -r v; do
    n="${v%[sm]}"; u="${v#"$n"}"
    [ "$u" = "m" ] && n=$((n * 60))
    if [ -z "$min_scrape" ] || [ "$n" -lt "$min_scrape" ]; then min_scrape="$n"; fi
  done <<<"$scrapes"
  [ -n "$min_scrape" ]

  # 원장이 선언한 서브쿼리 step (기계 판독 마커 — 산문의 역사 기록과 구별된다)
  local marker step_raw step_s
  marker="$(grep -oE '<!-- ledger:subquery-step=[0-9]+[sm] -->' "$ROOT/docs/memory-ledger.md")"
  [ -n "$marker" ]
  [ "$(grep -c . <<<"$marker")" -eq 1 ]
  step_raw="$(grep -oE '[0-9]+[sm]' <<<"$marker")"
  step_s="${step_raw%[sm]}"
  case "$step_raw" in *m) step_s=$((step_s * 60)) ;; esac

  # step ≤ scrape이어야 전 샘플이 포착된다
  if [ "$step_s" -gt "$min_scrape" ]; then
    echo "원장 서브쿼리 step ${step_s}s > 스크레이프 간격 ${min_scrape}s — peak가 과소평가된다" >&2
    return 1
  fi
}
