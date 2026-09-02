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

# 합계 프로즈는 **쓰기 경로의 앵커**다 — `tools/lib/ledger-totals.ts`의 `TOTALS_RE`가 매치하지 않으면
# create-app/provision-cache/teardown-app/teardown-resource가 원장 단계에서 throw로 죽는다. 그런데 그
# fail-loud는 디스패처가 돌 때만 들리고, 픽스처는 전부 올바른 형식을 품고 있어 어떤 테스트도 red가
# 아니었다: 2026-08-31 정정이 `≈`를 떨어뜨린 뒤 세 디스패처가 이틀간 동작 불능이었는데 CI는 초록이었다.
# 값 축도 같다 — 손편집이 행을 고치고 합계 줄을 안 고치면 원장 산문이 매니페스트와 다른 숫자를 말한다.
# ⚠️ 정규식은 **lib에서 import**한다. 사본을 여기 다시 적으면 그 사본이 드리프트해 가드가 공허해진다.
@test "the real ledger Totals prose matches the write-path anchor and the row sums" {
  run bun -e '
    const [ledgerPath, libPath] = process.argv.slice(1);
    const fs = require("node:fs");
    import("file://" + libPath).then(m => {
      const text = fs.readFileSync(ledgerPath, "utf8");
      const hit = text.match(m.TOTALS_RE);
      if (!hit) { console.error("NO-MATCH"); process.exit(1); }
      const [req, limit] = hit[0].match(/\d+/g).map(Number);
      const rows = m.parseLedgerRows(text);
      if (rows.length === 0) { console.error("NO-ROWS"); process.exit(1); }
      const sumReq = rows.reduce((a, r) => a + r.reqMi, 0);
      const sumLimit = rows.reduce((a, r) => a + r.limitMi, 0);
      if (req !== sumReq || limit !== sumLimit) {
        console.error(`MISMATCH prose=${req}/${limit} rows=${sumReq}/${sumLimit}`); process.exit(1);
      }
      console.log("ok");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$ROOT/docs/memory-ledger.md" "$ROOT/tools/lib/ledger-totals.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

# 위 @test의 대조군 — 판정이 실제로 형식을 재는지 사본으로 확인한다(`≈` 하나만 뺀다).
# 이것이 없으면 위 @test는 "실 원장이 지금 맞다"만 말하고, 판정 조건 자체가 무증인으로 남는다.
@test "a copy with one missing approx sign is red (the format axis is really measured)" {
  local copy="$BATS_TEST_TMPDIR/ledger-mutant.md"
  sed '0,/req ≈/s/req ≈/req/' "$ROOT/docs/memory-ledger.md" > "$copy"
  run grep -c 'req ≈' "$copy"
  [ "$output" = "0" ]
  run bun -e '
    const [ledgerPath, libPath] = process.argv.slice(1);
    const fs = require("node:fs");
    import("file://" + libPath).then(m => {
      if (!m.TOTALS_RE.test(fs.readFileSync(ledgerPath, "utf8"))) { console.log("no-match"); return; }
      console.log("MATCHED");
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$copy" "$ROOT/tools/lib/ledger-totals.ts"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^no-match$"
}
