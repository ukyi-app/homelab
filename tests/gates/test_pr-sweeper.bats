#!/usr/bin/env bats
# races-3/obs-5: strict=true + 비동기 auto-merge면 2번째 PR이 main 뒤에서 멈춘다(BEHIND).
# 스위퍼가 auto-merge-pending인데 behind인 봇 PR을 주기적으로 update-branch해 수렴시킨다.
# ⚠️ 중간 단언은 [ ]만. @test 이름은 영어.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  F="$ROOT/.github/workflows/pr-sweeper.yaml"
  command -v yq >/dev/null || skip "yq required"
}

@test "pr-sweeper runs on a schedule (cron) and manual dispatch only" {
  run yq '.on.schedule[0].cron' "$F"
  [ -n "$output" ]
  [ "$output" != "null" ]
  run yq '.on.workflow_dispatch' "$F"
  [ "$output" != "null" ]
  # push/pull_request 트리거 금지(스위퍼는 스케줄 전용)
  run yq '.on.push' "$F"
  [ "$output" == "null" ]
}

@test "pr-sweeper uses the writer App token (PR-first), not a standing PAT" {
  grep -q "HOMELAB_WRITER_APP_ID" "$F"
  ! grep -q "DEPLOY_BOT_PAT" "$F"
}

@test "pr-sweeper updates behind branches via gh pr update-branch" {
  grep -q "update-branch" "$F"
}

@test "pr-sweeper surfaces update-branch failures (tracks + exits nonzero, not silent green) (restale3 F2)" {
  # ⚠️ codex restale3 F2: update-branch 실패를 ::warning::로 삼키고 green 종료하면 멈춘 PR이 무알림으로 묻힌다.
  # 실패 PR을 모아 exit 1(→ failure() telegram 발화)해야 한다. 정적 단언: 실패 추적 변수 + nonzero 종료.
  grep -q 'failed=' "$F"
  grep -qE 'failed.*exit 1' "$F"
}

@test "pr-sweeper scopes to bot branches only (head prefix filter)" {
  # bump/ bump-poll/ create-database/ create-cache/ create-app/ onboard/ update-secrets/ 만 손댄다
  grep -qE 'bump|create-|onboard|update-secrets' "$F"
}

@test "pr-sweeper notifies on failure via the telegram action (mutation source label)" {
  run yq '[.jobs[].steps[]? | select(.uses=="./.github/actions/telegram-notify")] | length' "$F"
  [ "$output" != "0" ]
  grep -q "source: 변이" "$F"
}

@test "pr-sweeper checks out the repo before using the local telegram-notify action (F8)" {
  # ⚠️ codex pass2 F8: 로컬 액션은 체크아웃된 레포에서 resolve된다 — checkout이 telegram-notify보다 앞서야.
  co=$(grep -nE 'uses:[[:space:]]*actions/checkout' "$F" | head -1 | cut -d: -f1)
  tg=$(grep -nE 'uses:[[:space:]]*\./\.github/actions/telegram-notify' "$F" | head -1 | cut -d: -f1)
  [ -n "$co" ]
  [ -n "$tg" ]
  [ "$co" -lt "$tg" ]
}

@test "auto-merge workflows phrase success as merge-pending, not deployed" {
  WF="$ROOT/.github/workflows"
  # obs-5: auto-merge 성공은 "PR 무장"이지 "배포 완료"가 아니다 — 알림 body가 그 사실을 드러낸다.
  for f in _create-database.yaml _create-cache.yaml _update-secrets.yaml; do
    grep -q "머지 대기" "$WF/$f" || { echo "missing '머지 대기' notice in $f"; false; }
  done
}

@test "no workflow uses a local ./.github/actions composite without an actions/checkout (F8 systemic)" {
  # F8 재발 방지: 로컬 composite를 쓰는 모든 워크플로는 checkout을 가져야 한다(파일 단위 presence 가드).
  WFDIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/.github/workflows"
  bad=""
  for w in "$WFDIR"/*.yml "$WFDIR"/*.yaml; do
    [ -e "$w" ] || continue
    if grep -qE 'uses:[[:space:]]*\./\.github/actions/' "$w"; then
      grep -qE 'uses:[[:space:]]*actions/checkout' "$w" || bad="$bad $(basename "$w")"
    fi
  done
  [ -z "$bad" ] || { echo "로컬 액션 쓰는데 checkout 없는 워크플로:$bad"; false; }
}
