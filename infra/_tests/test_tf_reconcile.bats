#!/usr/bin/env bats
# tf-reconcile.yaml의 안전 불변식 가드:
#  - github/tailscale 루트는 plan-only(무인 apply 절대 금지 — 신뢰 앵커/고-blast-radius).
#  - cloudflare 루트만 apply하며 destroy 가드를 유지한다.
#  - 시크릿 부재로 인한 skip은 **관측 가능해야 한다**(G-09 준비상태 회계) — 예전엔 그 skip을
#    "바람직한 상태"로 못박고 있었는데, 실제로는 신뢰 앵커 감시가 통째로 죽는 상태였다.
#
#
# terraform 비의존 — required gate가 수집(run-bats, tests/.ci-exclude 미등재). 12개 @test 전부가 워크플로
# 파일에 대한 순수 grep이라 terraform 바이너리가 필요 없다. 예전엔 「terraform 의존」 사유로 .ci-exclude에
# 있었고 유일 실행처가 iac.yaml advisory였는데, 그 워크플로의 `paths` 필터는 `.github/**`를 안 봐서
# **tf-reconcile.yaml만 바꾸는 PR에서는 아예 돌지 않았다** — 이 파일이 지키는 불변식을 위반할 수 있는
# 바로 그 PR이 무증인이었다. required check는 `gate` 하나뿐이다(docs/decisions/0003).
# cf. 형제 선례 infra/cloudflare/test_apps_structure.bats:2-5(같은 클래스의 advisory 우회).
#
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일($WF)이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
#    2026-08-29 격리 트리 실측: tf-reconcile.yaml을 리네임하면 이 파일의 12개 중 **아래 두 개만**
#    초록으로 남았다(형제 양성 단언이 없는 @test들이다). 즉 plan-only 계약과 alert-and-skip 계약이
#    대상 부재에 공허했다.

WF="$BATS_TEST_DIRNAME/../../.github/workflows/tf-reconcile.yaml"

@test "github/tailscale drift jobs exist" {
  run grep -qE '^  drift-github:' "$WF"
  [ "$status" -eq 0 ]
  run grep -qE '^  drift-tailscale:' "$WF"
  [ "$status" -eq 0 ]
}

@test "github/tailscale roots are NEVER applied/destroyed unattended (plan-only)" {
  # 신뢰 앵커 보호: 이 두 루트에 대한 apply/destroy 호출이 워크플로에 있으면 안 된다.
  # ⚠️ 형제 양성 단언이 없는 @test다 — 예전 `-ne 0`에서는 워크플로 리네임에 홀로 초록이었다(실측).
  run grep -nE 'chdir=infra/(github|tailscale)[^|]*(apply|destroy)' "$WF"
  [ "$status" -eq 1 ]
}

@test "github/tailscale drift jobs use plan with detailed-exitcode" {
  run grep -qE 'chdir=infra/github plan .*-detailed-exitcode' "$WF"
  [ "$status" -eq 0 ]
  run grep -qE 'chdir=infra/tailscale plan .*-detailed-exitcode' "$WF"
  [ "$status" -eq 0 ]
}

# ⚠️ 이 자리엔 "drift jobs skip when secrets absent (preflight gate)"가 있었다. 두 가지가 틀렸다:
#   ① 이름이 **skip을 바람직한 상태로 못박았다.** 실제로 그 skip은 신뢰 앵커(branch protection·CI
#      시크릿·tailscale ACL) 드리프트 감시가 **통째로 죽는** 상태다 — 2026-07-27 실측으로 두 job이
#      한 번도 실행된 적이 없음이 확인됐고, 그동안 매 30분 run은 초록이었다.
#   ② 단언이 이름과 달랐다. `grep -c 'configured=true' >= 3`은 **게이트가 몇 개 있는지**만 셌고
#      skip 자체는 검증하지 않았다(프록시 단언). accounting job을 추가해도 이 수는 줄지 않는다.
# 대체 계약: 게이트가 있다는 사실이 아니라 그 게이트가 **관측 가능한가**를 본다(G-09).
@test "step-level gated drift jobs promote outputs.executed (observability of a silent skip)" {
  # 스텝-레벨 게이트는 job이 항상 success다 — 이 승격이 없으면 회계가 원리적으로 아무것도 못 잡는다.
  run grep -c 'executed: ${{ steps.drift.outputs.executed }}' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
  # 승격의 소스 — plan 스텝이 실제로 진입했을 때만 true가 된다.
  run grep -c 'echo "executed=true" >> "\$GITHUB_OUTPUT"' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "an accounting job outside the gates observes every readiness-gated job" {
  # 게이트 **밖**이어야 한다: skip된 job 안의 스텝은 if: always()여도 실행되지 않는다(라이브 실측).
  run grep -qE '^  accounting:' "$WF"
  [ "$status" -eq 0 ]
  run grep -q 'needs: \[preflight, reconcile, drift-github, drift-tailscale\]' "$WF"
  [ "$status" -eq 0 ]
  run grep -q 'if: ${{ !cancelled() }}' "$WF"
  [ "$status" -eq 0 ]
  run grep -q 'check-workflow-readiness.ts --workflow tf-reconcile.yaml' "$WF"
  [ "$status" -eq 0 ]
  # 권위 계약(원장 ↔ 워크플로 양방향 + 런타임 판정)은 required gate가 지킨다 — 이 파일도 이제 그 gate가
  # 수집하므로(헤더 참고) 같은 venue다. 여기서는 ci.yaml에 그 스텝이 살아 있는지만 확인한다.
  run grep -q 'check-workflow-readiness' "$BATS_TEST_DIRNAME/../../.github/workflows/ci.yaml"
  [ "$status" -eq 0 ]
}

@test "cloudflare reconcile keeps the destroy guard" {
  run grep -q 'uses: ./.github/actions/tf-destroy-guard' "$WF"
  [ "$status" -eq 0 ]
  run grep -qE 'chdir=infra/cloudflare apply' "$WF"
  [ "$status" -eq 0 ]
}

@test "cloudflare reconcile passes allow=app-DNS + allow_max cap (teardown auto, mass blocked)" {
  # app DNS(app[*])만 자동 apply, apex/www는 보호, allow_max로 대량 삭제 차단.
  # ⚠️ 부분문자열 grep은 값 axis에 무증인이다 — allow에 `|^cloudflare_dns_record\.public\[`를
  #    덧대도(apex/www까지 자동 허용) grep -cF는 그대로 매치한다(실측). 콜사이트 1개라 파일
  #    수준 정확 등식으로 닫는다(형제 관용구 infra/_tests/test_tf_static.bats:15).
  [ "$(grep -cE '^[[:space:]]+allow:' "$WF")" -eq 1 ]
  [ "$(grep -cF "allow: '^cloudflare_dns_record\\.app\\['" "$WF")" -eq 1 ]
  [ "$(grep -cF "allow_max: '1'" "$WF")" -eq 1 ]
}

@test "cloudflare reconcile uses the tf-destroy-guard composite (block) not inline jq" {
  run grep -q 'uses: ./.github/actions/tf-destroy-guard' "$WF"
  [ "$status" -eq 0 ]
  # 인라인 destroy jq가 reconcile에서 제거됐는지(composite로 수렴) — 위 composite 단언이 같은 파일의
  # 실재를 함께 증언하므로 이 자리는 rc 구별만 채우면 닫힌다.
  run grep -F 'select(. == "delete")' "$WF"
  [ "$status" -eq 1 ]
}

@test "reconcile delete guard is alert-and-skip (does not hard-fail the job on delete)" {
  # drift-2: delete가 있어도 reconcile job 자체는 실패시키지 않는다(::warning:: + telegram). ⚠️ F3: saved-plan
  # apply는 원자적이라 delete 포함 시 apply 전체가 skip되며(부분 수렴 불가), owner 로컬 apply 후 다음 주기에 수렴.
  # 즉 reconcile 경로엔 'exit 1'로 잡을 죽이는 인라인 destroy 분기가 없어야 한다(가드는 continue-on-error로 강등).
  # ⚠️ 형제 양성 단언이 없는 @test다 — 예전 `-ne 0`에서는 워크플로 리네임에 홀로 초록이었다(실측).
  run grep -nE '무인 apply 차단.*exit 1|exit 1[[:space:]]*#.*destroy' "$WF"
  [ "$status" -eq 1 ]
}

@test "reconcile guard step is continue-on-error and emits a warning (not job failure)" {
  run grep -qE 'continue-on-error:[[:space:]]*true' "$WF"
  [ "$status" -eq 0 ]
}

@test "reconcile telegram fires on delete-blocked drift (owner-local apply nudge)" {
  # delete 차단 시에도 telegram이 발화하도록 알림 조건이 guard result(blocked-delete)를 포함해야 한다.
  # ⚠️ 옛 술어 `grep -qE "guard|blocked-delete|result"`는 항진식이었다 — 세 토큰은 이 워크플로 어디에나
  #    있어서 $WF 실재만 증언했다. 실측: 발화 조건을 `if: failure()`로 좁히고 status의
  #    blocked-delete 분기를 지워도 이 파일 12/12 · 형제 gate 7/7 전건 초록이었다(무성화 완료).
  # 스텝 **실재**는 tests/gates/test_telegram-callsites.bats의 콜사이트 수 SSOT(tf-reconcile.yaml 4)가
  # 증언한다(스텝 통째 삭제 = 그 gate red 실측). 여기서는 그 gate가 원리적으로 못 보는 **발화 조건**만 본다.
  # `if:` 리터럴은 이 파일에서 유일하다(:250·:374는 `steps.pf.outputs.configured == 'true' && (…)` 접두).
  run grep -qF "if: failure() || steps.drift.outputs.drift == 'true'" "$WF"
  [ "$status" -eq 0 ]
  run grep -qF "steps.guard.outputs.result == 'blocked-delete' && 'drift'" "$WF"
  [ "$status" -eq 0 ]
}

@test "reconcile apply gates on guard result==ok and fails the job on result==error (F1)" {
  # ⚠️ codex pass5 F1: outcome은 delete-block과 내부 오류를 구분 못 한다 — apply는 result=='ok'에서만,
  # result=='error'(가드 자체 깨짐)는 잡을 loud 실패시켜야(조용한 skip 금지).
  run grep -qE "steps\.guard\.outputs\.result == 'ok'" "$WF"
  [ "$status" -eq 0 ]
  run grep -qE "steps\.guard\.outputs\.result == 'error'" "$WF"
  [ "$status" -eq 0 ]
}
