#!/usr/bin/env bats
# 검사 코드 출처(aiops-provenance) 통합 회귀 — 실제 임시 Git main→proposal 분기 위에서
# 캡처 시점·제안 커밋 분리·main 재checkout·잘못된/부재 출처·오염된 워크트리를 기록한다.
#
# collector의 main 도달 규칙(수집 계약 `artifact-revision-not-trusted-main`)은 네트워크 예외 없이
# 그대로 시험한다: revision이 main 조상이거나 동일해야 수용된다. 거부 방향도 함께 낸다.
# PR 생성/미변경/실패는 여기서 기록하고, skip(잡 미실행=artifact 부재)은 정적 계약이 관측 스텝의
# `if: always()`와 캡처 스텝의 조건부를 잰다(tools/tests/test_aiops-producers.bats).
bats_require_minimum_version 1.5.0
setup() {
  cd "$BATS_TEST_DIRNAME/../.." || exit 1
  ROOT="$PWD"
  CAPTURE="$ROOT/.github/actions/aiops-provenance/capture.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" symbolic-ref HEAD refs/heads/main # 기본 브랜치명을 main으로 고정(수집 계약과 동일)
  git -C "$REPO" config user.name fixture
  git -C "$REPO" config user.email fixture@example.test
  printf 'inspection source\n' > "$REPO/tool.txt"
  git -C "$REPO" add tool.txt
  git -C "$REPO" commit -qm 'main: inspection source'
  MAIN_SHA="$(git -C "$REPO" rev-parse HEAD)"
  RUN_HEAD="$MAIN_SHA"
  SOURCE_REV=""
  PROPOSAL_REV=""
  JOB_RESULT="success"
}

# 출처 캡처 — 워크플로가 checkout 직후 실행하는 바이트 그대로.
capture() { # $1=worktree $2=GITHUB_OUTPUT path
  ( cd "$1" && GITHUB_OUTPUT="$2" RUN_HEAD_SHA="${RUN_HEAD:-}" bash "$CAPTURE" )
}

# 관측 writer — composite가 넘기는 env 계약 그대로.
observe() { # $1=observation.json path
  AIOPS_PRODUCER='tf-reconcile.yaml/reconcile' AIOPS_TARGET=cloudflare AIOPS_JOB_RESULT="$JOB_RESULT" \
    AIOPS_STEPS='{"drift":{"outcome":"success","outputs":{"drift":"false"}}}' \
    GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_REPOSITORY=ukyi-app/homelab GITHUB_SHA="$RUN_HEAD" \
    AIOPS_SOURCE_REVISION="$SOURCE_REV" AIOPS_PROPOSAL_REVISION="$PROPOSAL_REV" \
    bun "$ROOT/tools/aiops-observation.ts" --output "$1"
}

# collector의 main 도달 규칙(출처가 main 조상이거나 동일해야 수용).
accepts_revision() { git -C "$REPO" merge-base --is-ancestor "$1" main; }

proposal_commit() { # main 위 제안 분기 커밋 — pr-first-commit의 checkout -b + commit을 재현
  git -C "$REPO" checkout -q -b proposal
  printf 'proposal change\n' >> "$REPO/tool.txt"
  git -C "$REPO" commit -qam 'proposal: change'
  git -C "$REPO" rev-parse HEAD
}

@test "capture pins the checked-out revision before any proposal commit moves HEAD" {
  run capture "$REPO" "$BATS_TEST_TMPDIR/out-main"
  [ "$status" -eq 0 ]
  grep -qx "source-revision=$MAIN_SHA" "$BATS_TEST_TMPDIR/out-main"

  proposal_sha="$(proposal_commit)"
  [ "$proposal_sha" != "$MAIN_SHA" ]
  # 캡처는 변이 앞에서 고정됐으므로 제안 커밋 뒤에도 값이 그대로다.
  grep -qx "source-revision=$MAIN_SHA" "$BATS_TEST_TMPDIR/out-main"
  run accepts_revision "$MAIN_SHA"
  [ "$status" -eq 0 ]
}

@test "a proposal branch commit is not main-reachable and must never be the revision" {
  proposal_sha="$(proposal_commit)"
  run accepts_revision "$proposal_sha"
  [ "$status" -eq 1 ] # 정확한 비-조상(rc 2+: 저장소/ref 오류는 red로 남긴다)
  run accepts_revision "$MAIN_SHA"
  [ "$status" -eq 0 ]

  # 늦게 캡처하면 주변 HEAD(제안 커밋)를 출처로 잡는다 — 정적 순서 계약이 막는 형태를 기록한다.
  run capture "$REPO" "$BATS_TEST_TMPDIR/out-late"
  [ "$status" -eq 0 ]
  grep -qx "source-revision=$proposal_sha" "$BATS_TEST_TMPDIR/out-late"
}

@test "observation keeps source and proposal revisions in separate fields" {
  proposal_sha="$(proposal_commit)"
  SOURCE_REV="$MAIN_SHA"
  PROPOSAL_REV="$proposal_sha"
  observe "$BATS_TEST_TMPDIR/observed.json"

  jq -e --arg s "$MAIN_SHA" --arg p "$proposal_sha" --arg h "$MAIN_SHA" \
    '.revision == $s and .proposalRevision == $p and .runHeadSha == $h' "$BATS_TEST_TMPDIR/observed.json"
  run accepts_revision "$(jq -r .revision "$BATS_TEST_TMPDIR/observed.json")"
  [ "$status" -eq 0 ]
  run accepts_revision "$(jq -r .proposalRevision "$BATS_TEST_TMPDIR/observed.json")"
  [ "$status" -eq 1 ] # 제안 커밋은 main 밖 — 출처로 실리면 collector가 거부할 값이다
}

@test "a main recheckout keeps runHead and source as distinct axes" {
  # 캡처 시점 main(M1) 뒤 main이 전진한다 — 실행 HEAD(GITHUB_SHA)는 M2, 출처는 M1.
  printf 'later main\n' >> "$REPO/tool.txt"
  git -C "$REPO" commit -qam 'main: advance after checkout'
  RUN_HEAD="$(git -C "$REPO" rev-parse HEAD)"
  [ "$RUN_HEAD" != "$MAIN_SHA" ]

  SOURCE_REV="$MAIN_SHA"
  observe "$BATS_TEST_TMPDIR/recheckout.json"
  jq -e --arg s "$MAIN_SHA" --arg h "$RUN_HEAD" \
    '.revision == $s and .runHeadSha == $h and (has("proposalRevision") | not)' "$BATS_TEST_TMPDIR/recheckout.json"
  # 출처가 runHead와 달라도 main 조상이면 수용된다(수집 계약의 ahead/identical 경로).
  run accepts_revision "$MAIN_SHA"
  [ "$status" -eq 0 ]
}

@test "a failed check still records the captured source" {
  JOB_RESULT="failure"
  SOURCE_REV="$MAIN_SHA"
  observe "$BATS_TEST_TMPDIR/failed.json"
  jq -e --arg s "$MAIN_SHA" '.status == "warning" and .completed == false and .revision == $s' "$BATS_TEST_TMPDIR/failed.json"
  run accepts_revision "$(jq -r .revision "$BATS_TEST_TMPDIR/failed.json")"
  [ "$status" -eq 0 ]
}

@test "a dirty worktree at capture time is refused" {
  printf 'local edit\n' >> "$REPO/tool.txt"
  run capture "$REPO" "$BATS_TEST_TMPDIR/out-dirty"
  [ "$status" -eq 1 ]
  grep -Fq 'aiops-provenance' <<<"$output"
  [ ! -s "$BATS_TEST_TMPDIR/out-dirty" ]
}

@test "an untracked file also taints the capture" {
  printf 'stray\n' > "$REPO/stray.txt"
  run capture "$REPO" "$BATS_TEST_TMPDIR/out-untracked"
  [ "$status" -eq 1 ]
  grep -Fq 'aiops-provenance' <<<"$output"
  [ ! -s "$BATS_TEST_TMPDIR/out-untracked" ]
}

@test "a missing or malformed source revision cannot produce an artifact" {
  for source in "" "not-a-sha" "${MAIN_SHA}0" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; do
    SOURCE_REV="$source"
    run observe "$BATS_TEST_TMPDIR/bad.json"
    [ "$status" -eq 1 ]
    grep -Fq 'AIOps observation invalid or not written' <<<"$output"
    [ ! -e "$BATS_TEST_TMPDIR/bad.json" ]
  done
  # 잘못된 제안 축도 산출물을 만들지 않는다(오표기 메타데이터 차단).
  SOURCE_REV="$MAIN_SHA"
  PROPOSAL_REV="not-a-sha"
  run observe "$BATS_TEST_TMPDIR/bad-proposal.json"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/bad-proposal.json" ]
}

@test "provenance revision validation unit tests are included in the CI gate" {
  run bun test "$ROOT/tools/tests/aiops-provenance.test.ts"
  [ "$status" -eq 0 ]
}
