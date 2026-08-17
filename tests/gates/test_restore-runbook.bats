#!/usr/bin/env bats
# DR 런북(`docs/runbooks/restore.md`) ↔ 매니페스트 결합 가드.
#
# ⚠️ **이 가드가 왜 tracked 위치에 있는가.** 원본은 `docs/runbooks/test_restore_runbook.bats`였는데
#    그 디렉토리가 gitignored라 `scripts/run-bats.sh`(= `git ls-files '*test_*.bats'`)가 **한 번도
#    수집한 적이 없다** — @test 3건이 존재만 하고 실행된 적 없는 죽은 가드였다(실측 2026-08-17).
#    여기로 옮겨야 최소한 owner 로컬 `make ci`에서는 실제로 돈다.
#
# ⚠️ **CI에서는 파일이 없어 SKIP된다.** 그 자체가 이 레포가 싫어하는 '무측정 초록'에 가깝다는 것을
#    안다 — 그래서 SKIP 사유를 요란하게 남기고, 판정은 런북이 실재하는 곳(owner 로컬)에 맡긴다.
#    런북을 tracked로 올리는 것은 답이 아니다: 레포가 **public**이고(`gh repo view` → PUBLIC)
#    운영 절차·토폴로지를 공개할 수 없다. 자격증명은 들어 있지 않지만 절차 자체가 보호 대상이다.
#
# ⚠️ @test 이름은 영어만(check-skeleton의 CJK 가드). 중간 부정은 마지막 명령으로만.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RB="$ROOT/docs/runbooks/restore.md"
  CLUSTER="$ROOT/platform/cnpg/prod/cluster.yaml"
  HEDGE="$ROOT/platform/cnpg/prod/pgdump-hedge-cronjob.yaml"
}

@test "restore runbook covers all three recovery paths (R2 barman, pg_dump hedge, local basebackup)" {
  [ -f "$RB" ] || skip "SKIP: docs/runbooks/restore.md 부재(gitignored) — CI에서는 평가 불가. owner 로컬에서만 판정된다"
  grep -qi 'bootstrap.recovery' "$RB"
  grep -qi 'pg_restore' "$RB"
  grep -qi 'pg_basebackup' "$RB"
}

@test "restore runbook gives a PITR example and names the canary row-count gate" {
  [ -f "$RB" ] || skip "SKIP: docs/runbooks/restore.md 부재(gitignored)"
  grep -qi 'recoveryTarget' "$RB"
  grep -qi 'restore_canary' "$RB"
}

@test "runbook path A recovers from the archive prefix the live cluster actually WRITES to" {
  # 🔴 이 @test가 이 파일의 존재 이유다. 2026-08-17 컷오버에서 main의 쓰기 serverName이
  #    pg → pg-nuc로 바뀌었는데 런북은 `serverName: pg`(2026-08-13에 얼어붙은 Mac 아카이브)를
  #    가리킨 채 남아 있었다. 두 prefix가 공존하므로(PONR 1 미실행) 그 경로는 **실패하지 않고
  #    성공하고**, 컷오버 이후 전 기간의 쓰기가 조용히 사라진다. 적대 검증이 치명으로 잡았다.
  # ⚠️ 기대값은 **하드코딩하지 않고 매니페스트에서 파생한다**(derive-don't-declare).
  [ -f "$RB" ] || skip "SKIP: docs/runbooks/restore.md 부재(gitignored)"
  want="$(yq -e '.spec.plugins[] | select(.name == "barman-cloud.cloudnative-pg.io") | .parameters.serverName' "$CLUSTER")"
  [ -n "$want" ]
  # 런북은 (a) 그 값을 직접 적거나 (b) 라이브에서 파생하라고 지시하거나 — 둘 중 하나여야 한다.
  run bash -c "grep -qF 'serverName: $want' '$RB' || grep -qF 'parameters.serverName' '$RB'"
  [ "$status" -eq 0 ]
}

@test "runbook path A does not still point at the frozen Mac-era archive prefix" {
  # 위 @test는 '올바른 값이 있다'만 본다 — 옛 값이 **함께** 남아 있으면 사람이 그걸 복사한다.
  # 코드블록 안의 실제 지시만 본다(주석/설명 줄은 옛 prefix를 정당하게 인용할 수 있다).
  [ -f "$RB" ] || skip "SKIP: docs/runbooks/restore.md 부재(gitignored)"
  run bash -c "grep -vE '^[[:space:]]*(>|#)' '$RB' | grep -cE 'serverName:[[:space:]]*pg[[:space:]]*[},]'"
  [ "$output" = "0" ]
}

@test "runbook path B names the pgdump prefix the hedge CronJob actually writes to" {
  # 같은 클래스의 두 번째 자리. 라이브는 pgdump-nuc/에 덤프하는데 런북이 pgdump/를 적고 있었다.
  [ -f "$RB" ] || skip "SKIP: docs/runbooks/restore.md 부재(gitignored)"
  pfx="$(grep -oE 'DUMP_PREFIX="[^"]*"' "$HEDGE" | head -1 | sed 's/.*\///; s/"$//')"
  [ -n "$pfx" ]
  grep -qF "$pfx/" "$RB"
}
