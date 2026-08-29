#!/usr/bin/env bats
# 부재 단언 **뮤테이션 증인** — `tests/gates/`·`tests/` 두 레인의 부재 단언이 대상이 사라지면
# 실제로 red가 되는지를 격리 트리에서 **실행으로** 증언한다.
#
# 병(SSOT: docs/traps-detail.md 「열거 붕괴 → vacuous green」): grep은 대상 부재/읽기불가에 rc **2**를
# 내는데 `[ "$status" -ne 0 ]`은 그것을 무매치(rc 1)와 구별하지 않는다 — 파일이 리네임/삭제되면 부재
# 단언이 조용히 통과한다. 디렉토리 피연산자는 `-eq 1`로도 안 닫힌다(빈 디렉토리 재귀 grep은 rc **1**):
# 그 축은 setup의 실재 단언 + @test 안의 양성 대조가 닫는다. 처방이 두 겹인 이유가 그것이다.
#
# `scripts/check-bats-style.sh`의 정적 부재-단언 거부와 **다른 축**이다(중복 아님):
#   · 정적 가드 = 소스에 `-ne 0` 부재 단언이 **적혀 있는가**(형태). 재유입을 diff에서 막는다.
#   · 이 증인   = 전환된 단언이 **대상 부재를 실제로 잡는가**(동작). 형태가 맞아도 디렉토리 피연산자거나
#     양성 대조가 빠지면 여전히 vacuous인데, 그건 소스를 읽어서는 원리적으로 판정할 수 없다.
# 둘 다 있어야 "규약이 적혀 있다"와 "규약이 작동한다"가 함께 선다.
#
# 레인 구성 — 레인 A·B는 처방의 **양성 대조/실재 단언** 겹을, 레인 C는 **`-eq 1` 연산자 자체**를 잰다.
# (A·B의 자리는 양성 대조가 먼저 잡으므로 연산자 단독 감도를 못 잰다 — C가 그 구멍을 메운다.)
# 레인 D·E는 도메인을 **`tests/`(gates 밖)**로 넓힌다 — 파괴 동사(destroy-node)와 시크릿 불변식
# (sealing key 백업 체인). 둘 다 해당 @test에 형제 단언이 **하나도 없어** `-eq 1`이 유일한 가드라,
# 리네임→red 자체가 C와 같은 '연산자 단독 감도'를 실 파일에서 재는 셈이다. 두 도메인을 각각
# 대표하므로 하나로 줄이지 않는다(레인당 비용은 트리 추출 ~0.4s가 전부다).
# ⚠️ `tests/test_sops-roundtrip.bats`는 레인으로 넣지 않는다 — 그 파일은 실 age 키 의존이라
#    `tests/.ci-exclude`에 있는데 이 증인은 required gate 안에 **있다**(`scripts/run-bats.sh --list`
#    실측: 증인 포함 · sops-roundtrip 제외). 중첩하면 키 없는 러너에서 이 게이트가 깨진다.
#    gate의 sops 커버리지는 ci.yaml의 'SOPS 왕복 (ephemeral CI 키)' 스텝이 따로 진다.
#
# ⚠️ @test 이름은 영어만 — 디렉토리 단위 실행에서 CJK 이름이 침묵 스킵된다(AGENTS.md).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패가 침묵 통과한다(AGENTS.md).
# ⚠️ 중첩 bats 호출에는 전부 `</dev/null` — bats는 stdin을 만지지 않아서, 안쪽 @test가 fd 0을 읽으면
#    호출자 stdin에서 영구 블록한다(AGENTS.md 「bats는 stdin을 만지지 않는다」).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  [ -d "$ROOT/tests/gates" ]
}

# 실 레포의 **워킹 트리**를 격리 사본으로 뽑는다. HEAD가 아니라 워킹 트리인 이유: 아직 커밋되지 않은
# 전환도 증언 대상이다(커밋 뒤에도 같은 명령이 그대로 성립한다). 실 레포는 절대 수정하지 않는다.
_tree() {
  t="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$t"
  ( cd "$ROOT" && git ls-files -z | tar --null -T - -cf - ) </dev/null | tar -x -C "$t"
  # 추출 자체의 비공허 바닥값 — 트리가 비면 아래 판정 전부가 자기 자신 vacuous가 된다.
  n="$(find "$t" -type f | wc -l | tr -d ' ')"
  [ "$n" -ge 200 ] || { echo "FAIL: 픽스처 추출이 붕괴했다(${n}건) — 판정 불가는 '통과'가 아니다" >&2; return 1; }
  echo "$t"
}

# ── 레인 A: 파일 피연산자 — 대상 리네임 ───────────────────────────────────────────────────────────
# 이 레인이 재현하는 공백 실증(01 티켓): `infra/github/variables.tf`를 `vars.tf`로 옮기고 PAT을
# 되살려도 전환 전 `test_auth.bats`는 초록이었다. grep이 rc 2를 내고 `-ne 0`이 그걸 통과로 읽었다.
@test "renaming a gate's target file turns that gate red (file operand)" {
  t="$(_tree a)"
  g="$t/tests/gates/test_auth.bats"
  # 비공허 증인 — 픽스처에 게이트와 그 대상이 실재해야 아래 판정에 증인이 선다.
  [ -s "$g" ]
  [ -s "$t/infra/github/variables.tf" ]

  # 뮤테이션 **전에 green이었다** — "원래부터 red"가 아님을 세운다. 필터가 0건이면 bats는
  # `1..0` + rc 1이므로, 이 두 줄이 필터 오타(이름 드리프트)의 증인도 겸한다.
  run bats -f 'no variable bot_pat' "$g" </dev/null
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^1\.\.1$'

  mv "$t/infra/github/variables.tf" "$t/infra/github/vars.tf"
  [ ! -e "$t/infra/github/variables.tf" ]

  run bats -f 'no variable bot_pat' "$g" </dev/null
  # rc 1 = 테스트 실패. 그 밖의 비-0(127 실행 불가 · `1..0` 테스트 없음)을 red로 읽지 않는다 —
  # 하네스 사고를 판정으로 오독하면 이 증인 자신이 vacuous가 된다.
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^not ok 1 '
}

# ── 레인 B: 디렉토리 피연산자 — 열거 도메인 공허화 ───────────────────────────────────────────────
# 여기서 `-eq 1`은 **아무것도 잡지 못한다**(빈 디렉토리 재귀 grep = rc 1 = 무매치와 동일). 잡는 것은
# setup의 실재 단언과 @test 안의 양성 대조다. 이 레인이 그 겹의 실효를 증언한다.
@test "emptying a gate's enumerated directory turns that gate red (directory operand)" {
  t="$(_tree b)"
  g="$t/tests/gates/test_ci-toolchain-pin.bats"
  wf="$t/.github/workflows"
  [ -s "$g" ]
  # 비공허 증인 — 열거 도메인이 실재하고 비어있지 않다.
  [ -d "$wf" ]
  [ "$(ls -1 "$wf" | wc -l | tr -d ' ')" -ge 10 ]

  run bats -f 'unpinned get-helm-3' "$g" </dev/null
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^1\.\.1$'

  # 디렉토리는 **남기고** 내용만 비운다 — 디렉토리째 지우면 rc 2가 되어 이 레인이 재는 축이 바뀐다.
  find "$wf" -mindepth 1 -delete
  [ -d "$wf" ]
  [ "$(ls -1A "$wf" | wc -l | tr -d ' ')" -eq 0 ]

  run bats -f 'unpinned get-helm-3' "$g" </dev/null
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^not ok 1 '
}

# ── 레인 C: 연산자 자체의 감도(자기 뮤테이션) ────────────────────────────────────────────────────
# `test_traps-sync.bats`의 역방향 tie는 부재 대상($D = docs/traps-detail.md)에 대한 양성 대조가
# **없다** — 그 자리에서는 `-eq 1`이 유일한 grep-rc 가드다.
#
# ⚠️ **이 레인의 원래 결론은 09번 착지로 무효가 됐다.** 도입 시(01번) 이 레인은 "연산자를 `-ne 0`으로
#    되돌리면 구멍이 다시 열린다(초록으로 돌아간다)"를 증언했고, 그것이 가능했던 이유는
#    `scripts/verify-traps.sh`가 `[ -f "$DETAIL" ]`로 감싸 traps-detail.md 부재를 **묵인**했기 때문이다.
#    09번이 정확히 그 fail-open을 닫았다(세 대상 전부 LEDGER와 같은 규율로 문다). 그래서 이제는
#    연산자를 되돌려도 같은 @test의 `:29`(`run bash verify-traps.sh; [ -eq 0 ]`)가 red를 만든다.
#
# ⇒ 이 레인은 그 **이중화 자체**를 증언하도록 바뀐다. 대상 부재가 두 겹으로 닫혔다는 것이 09번의
#    산출물이고, 한 겹(연산자)을 되돌려도 다른 겹(가드의 fail-closed)이 여전히 잡는다.
#    연산자 **단독** 감도는 레인 D·E가 실 파일에서 계속 잰다(그 자리들엔 형제 단언이 0건이라
#    verify-traps 같은 이중 겹이 없다).
@test "the missing SSOT is closed twice over (operator plus the guard's own fail-closed)" {
  t="$(_tree c)"
  g="$t/tests/gates/test_traps-sync.bats"
  [ -s "$g" ]
  [ -s "$t/docs/traps-detail.md" ]

  run bats -f 'reverse guard-path-tie' "$g" </dev/null
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^1\.\.1$'

  mv "$t/docs/traps-detail.md" "$t/docs/traps-detail.renamed.md"
  [ ! -e "$t/docs/traps-detail.md" ]
  run bats -f 'reverse guard-path-tie' "$g" </dev/null
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^not ok 1 '

  # 자기 뮤테이션 — 같은 트리에서 **연산자만** 되돌린다. sed -i는 BSD 비호환이라 임시 파일 경유.
  before="$(grep -c -F -e '-eq 1 ]' "$g" || true)"
  [ "$before" -eq 1 ]
  sed 's/-eq 1 ]/-ne 0 ]/g' "$g" > "$g.rev"
  after="$(grep -c -F -e '-eq 1 ]' "$g.rev" || true)"
  # 치환이 실제로 일어났다는 증거 — 0건 치환이면 아래 green은 아무것도 증언하지 않는다.
  [ "$after" -eq 0 ]
  mv "$g.rev" "$g"

  run bats -f 'reverse guard-path-tie' "$g" </dev/null
  # 09번 이후: 연산자를 되돌려도 여전히 red다 — verify-traps 자신이 대상 부재를 fail-closed로 문다.
  # 그 red가 **다른 줄**에서 난다는 것이 이중화의 증거다(연산자 줄이 아니라 :29의 가드 호출).
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^not ok 1 '
  printf '%s\n' "$output" | grep -Fq 'verify-traps.sh'
}

# ── 레인 D: tests/ 레인 — 파괴 동사(destroy-node) ─────────────────────────────────────────────────
# 02 티켓의 A 분류 ①. 이 @test에는 형제 단언이 **하나도 없다** — 전환 전 `-ne 0`에서는
# `scripts/destroy-node.sh`를 리네임하면 grep이 rc 2로 죽고도 통과해 그 파일에서 **혼자 초록으로
# 남았다**(실측). 그래서 여기서는 리네임→red가 곧 `-eq 1`의 서명이다.
@test "renaming destroy-node.sh turns the tests/ lane's K3S_RUN seam gate red" {
  t="$(_tree d)"
  g="$t/tests/test_destroy-node.bats"
  # 비공허 증인 — 게이트와 그 대상이 픽스처에 실재해야 아래 판정에 증인이 선다.
  [ -s "$g" ]
  [ -s "$t/scripts/destroy-node.sh" ]

  # ⚠️ 이 대상은 피연산자가 **상대 경로**다(`sh=scripts/destroy-node.sh`). 픽스처 밖에서 절대 경로로
  #    부르면 grep이 **실 레포**를 읽어 뮤테이션이 무력해지고 이 레인이 조용히 vacuous가 된다
  #    (실측: 그 형태는 리네임 후에도 ok였다). 아래 pre(green)/post(red) 쌍이 이 cd의 증인도 겸한다 —
  #    cd가 빠지면 post가 green이라 레인이 red로 알린다.
  cd "$t"

  # 뮤테이션 **전에 green이었다** — "원래부터 red"가 아님을 세운다. 필터가 0건이면 `1..0` + rc 1이라
  # 이 두 줄이 필터 오타(@test 이름 드리프트)의 증인도 겸한다.
  run bats -f 'every privileged command goes through the K3S_RUN seam' tests/test_destroy-node.bats </dev/null
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^1\.\.1$'

  mv scripts/destroy-node.sh scripts/destroy-node.renamed.sh
  [ ! -e scripts/destroy-node.sh ]

  run bats -f 'every privileged command goes through the K3S_RUN seam' tests/test_destroy-node.bats </dev/null
  # rc 1 = 테스트 실패만 red로 읽는다(127 실행 불가 · `1..0` 필터 0건은 판정이 아니다).
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^not ok 1 '
}

# ── 레인 E: tests/ 레인 — 시크릿 불변식(sealing key 백업 체인) ────────────────────────────────────
# 02 티켓의 A 분류 ②. 여기도 그 @test에 형제 단언이 없어 `-eq 1`이 유일한 가드다.
# 레인 D와 **다른 도메인**이라 함께 둔다(파괴 동사 vs 시크릿).
@test "renaming sealing-key-dr-gate.sh turns the tests/ lane's source-safety gate red" {
  t="$(_tree e)"
  g="$t/tests/test_sealed-secrets-restore.bats"
  [ -s "$g" ]
  [ -s "$t/scripts/sealing-key-dr-gate.sh" ]

  # ⚠️ 레인 D와 달리 cd가 필요 없다 — 이 파일은 setup에서 피연산자를 `$BATS_TEST_DIRNAME/..`로
  #    파생하므로(`ROOT`) 절대 경로 호출에서도 대상이 **자기 트리**다(실측: 픽스처 밖에서 불러도 red).
  run bats -f 'sealing-key-dr-gate is source-safe' "$g" </dev/null
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^1\.\.1$'

  mv "$t/scripts/sealing-key-dr-gate.sh" "$t/scripts/sealing-key-dr-gate.renamed.sh"
  [ ! -e "$t/scripts/sealing-key-dr-gate.sh" ]

  run bats -f 'sealing-key-dr-gate is source-safe' "$g" </dev/null
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^not ok 1 '
}
