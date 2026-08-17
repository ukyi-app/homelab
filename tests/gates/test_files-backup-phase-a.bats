#!/usr/bin/env bats
# 국면 A 한시 억제의 **값·형태 정합 가드**. SSOT는 infra/k3s-bootstrap/versions.env의
# BULK_MIGRATION_WINDOW_UNTIL이고, r4 FilesBackupStale의 재무장 unixtime은 그 **파생값**이다.
# 두 값이 서로 다른 파일(셸 env vs 룰 YAML)에 살아 한쪽만 바뀌는 드리프트가 구조적으로 가능하다.
# 선례: tests/test_pg-image-pin.bats(런타임에 SSOT를 파생할 수 없는 하드코딩 소비자 ↔ SSOT 대조).
#
# ⚠️ 이 가드는 **양방향**이다. 한 방향만 잠그면 나머지가 조용한 사고가 된다:
#   · 창이 열려 있는데 억제 절이 없다  → critical이 24/7 울려 채널이 둔감해진다(원래의 병).
#   · 창을 비웠는데 억제 절이 남아 있다 → 국면 B에서 백업 알림이 **죽은 채로** 넘어간다(더 나쁘다).
#     이 방향이 곧 "국면 B 전환 시 억제 제거"의 강제 장치다 — 주석이 아니라 게이트가 강제한다.
#
# ⚠️ **룰 본문은 `yq`로 파싱해서 본다. 파일 전체 grep을 쓰지 않는다.**
#    같은 파일의 **주석이 같은 리터럴(재무장 상수·`vector(time())`)을 담고 있어서**, 파일 grep은
#    주석을 집어 (a) 개수 단언을 깨거나 (b) 더 나쁘게 **주석의 상수를 검증하고 expr은 안 보는**
#    거짓 초록을 만든다. 배포되는 것은 expr뿐이므로 단언 대상도 expr뿐이어야 한다.
#
# ⚠️ @test 이름은 영어만 — CJK면 bats 디렉토리 실행에서 조용히 스킵된다(check-skeleton.sh 가드).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  V="$ROOT/infra/k3s-bootstrap/versions.env"
  R="$ROOT/platform/victoria-stack/prod/rules/r4-storage-backup.yaml"
  WIN="$(sed -n 's/^export BULK_MIGRATION_WINDOW_UNTIL="\(.*\)"$/\1/p' "$V")"
}

# 배포되는 expr **본문만** 꺼낸다(ConfigMap → 내장 룰 YAML → 해당 alert).
_expr() {
  yq -r '.data."r4.yaml"' "$R" \
    | yq -r '.groups[].rules[] | select(.alert=="FilesBackupStale") | .expr'
}
# expr 안의 재무장 unixtime(없으면 빈 문자열).
_rearm() { _expr | grep -oE 'vector\(time\(\)\) >= [0-9]+' | grep -oE '[0-9]+' | head -1; }

@test "the phase-A suppression clause exists exactly while the migration window is open" {
  got="$(_rearm)"
  if [ -n "$WIN" ]; then
    [ -n "$got" ]
  else
    [ -z "$got" ]
  fi
}

@test "the re-arm unixtime is midnight KST on the day after the window expires" {
  # ⚠️ 창이 비었으면(=국면 B) **skip이지 fail이 아니다.** 억제 절 부재는 위 @test가 이미 강제하고,
  #    여기서 fail을 내면 정상적인 국면 B 상태가 게이트를 통과하지 못한다 —
  #    "창을 비우면 자동 복귀"라는 설계를 가드가 스스로 막는 자리가 된다.
  [ -n "$WIN" ] || skip "국면 B(창 비움) — 억제 절 부재는 위 @test가 강제한다"
  # 창 만료일 00:00Z + 24h − 9h = 만료 **다음날** 00:00 KST.
  # (이 홈랩의 운영 타임존은 Asia/Seoul — versions.env의 HOST_TIMEZONE이 SSOT.)
  want="$(python3 -c 'import sys,datetime;w=sys.argv[1];print(int(datetime.datetime.strptime(w,"%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp())+86400-32400)' "$WIN")"
  [ "$(_rearm)" = "$want" ]
}

@test "only the absent branch is gated, so the staleness branch still pages during phase A" {
  # ⚠️ 이것이 이 파일에서 가장 중요한 단언이다. PromQL은 `and`가 `or`보다 강하게 결합하므로
  #    `A or B and on() C` = `A or (B and on() C)` — 시각 절을 **끝에 괄호 없이** 붙이면
  #    absent 가지에만 걸린다. 전체를 괄호로 묶으면(`(A or B) and on() C`) staleness 가지까지
  #    함께 죽는다. **두 형태 모두 문법상 유효해 vmalert `-dryRun`이 구별하지 못한다** —
  #    즉 이 단언이 없으면 그 회귀는 조용하다.
  #    실측(VictoriaMetrics v1.145.0): 끝에 붙인 형태에서 "실행자 배선 + 백업 stale" → 발화 유지.
  # ⚠️ 국면 B(창 비움)에서는 억제 절 자체가 없어야 하므로 형태를 볼 것이 없다 — skip이지 fail이 아니다.
  [ -n "$WIN" ] || skip "국면 B(창 비움) — 억제 절이 없는 것이 정상이다"
  e="$(_expr)"
  # (a) 억제 절이 expr의 **마지막** 줄이다(= or 뒤에 온다 → absent 가지에만 결합).
  printf '%s' "$e" | grep -v '^[[:space:]]*$' | tail -1 | grep -qF -- 'and on() (vector(time()) >='
  # (b) staleness 가지가 첫 줄에 그대로 살아 있다(양성 대조 — expr이 통째로 바뀌면 red).
  printf '%s' "$e" | head -1 | grep -qF -- '(time() - last_over_time(files_backup_last_success_timestamp[10d])) > 180000'
  # (c) expr 전체를 감싸는 괄호 형태가 아니다 — 첫 줄이 `((`로 시작하면 그 형태일 수 있다.
  run bash -c "printf '%s' \"\$1\" | head -1 | grep -qE '^[[:space:]]*\\(\\('" _ "$e"
  [ "$status" -ne 0 ]
}

@test "no firing-e2e harness uses this suppressed alert as its vacuity control" {
  # ⚠️ 음성 레그("발화 없음"이 판정)를 도는 e2e는 "확실히 발화하는 같은 그룹의 absent 가드 알림"을
  #    대조군으로 세워 vacuity를 배제한다. 그 대조군에 **시각 게이트를 걸면** replay(=현재 시각)에서
  #    발화가 불가능해져 하네스가 HARNESS FAULT(exit 2)로 죽는다. 억제를 도입하는 커밋은 대조군
  #    이동을 **같은 커밋에** 포함해야 한다 — 안 하면 required gate 2개가 동시에 RED다.
  # ⚠️ `:(exclude)`로 **이 파일 자신을 뺀다.** 패턴 리터럴을 본문에 담고 있어 자기 줄에 매치한다
  #    (레포 선례: tools/check-alert-rules.ts의 SELF 자기참조 제외).
  run git grep -nE 'CONTROL=FilesBackupStale|vme_firing[[:space:]]+"?FilesBackupStale' \
    -- 'tests/gates' ':(exclude)tests/gates/test_files-backup-phase-a.bats'
  [ "$status" -ne 0 ]
  # 양성 대조 — 대조군 관용구 자체는 살아 있다(패턴이 깨져 0건이 된 것을 '깨끗하다'로 오독하지 않는다).
  git grep -qE 'CONTROL=|vme_firing' -- 'tests/gates'
}
