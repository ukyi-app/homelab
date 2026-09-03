#!/usr/bin/env bats
# pr-first-commit composite — 5개 변이 reusable이 공유하는 PR-first 쓰기 SSOT의 **실행 증인**.
#
# ⚠️ 착지 전에는 잔여물 판정(action.yml의 [staged-completeness] 마커 구간)만 증인이 있었다
#    (tests/gates/test_staged-completeness.bats가 그 구간만 뽑아 돌린다). 그 뒤의 판정·부작용 —
#    skip-if-empty 멱등 분기, staged diff 판정, checkout/commit/push, gh pr create — 은 어떤 bats도
#    실행하지 않았다. 2026-09-03 뮤테이션 실측:
#      A) 멱등 판정을 `if true; then`(항상 no-op)으로 → 참조 bats 7개 전건 ok 수 불변
#      B) 쓰기 본체를 통째로 `echo result=pr`로 치환 → 같은 파일들 + test_auth·test_validate-mutation 불변
#    A 방향의 회귀는 _update-secrets.yaml:93이 job.status=success + 「변경 없음(동일 봉인본)」으로
#    텔레그램에 보내므로, 시크릿 회전이 '정상'으로 위장한 채 착지하지 않는다.
# ⚠️ 정적 grep으로는 못 닫는다 — 같은 파일에서 헤더 주석·입력 description이 증인 노릇을 하던
#    자리를 이미 밟았다(tests/gates/test_automerge-fallback.bats의 커맨드 줄 앵커).
#    관용구 선례: tools/tests/test_tf-r2-init.bats(composite run 본문을 픽스처에서 실제로 실행).
# ⚠️ 픽스처의 git은 **진짜 git이다** — 스텁 git은 `--cached` 의미론을 흉내내지 못한다.
#    격리는 GIT_CONFIG_GLOBAL/SYSTEM을 /dev/null로 끊어 오너의 전역 설정(gpgsign·hooksPath)이
#    본문의 `git commit`을 깨지 못하게 한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2에서 [[ ]] 실패는 침묵 통과.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  A="$REPO/.github/actions/pr-first-commit/action.yml"
  WF="$REPO/.github/workflows"
  [ -f "$A" ]
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
}

# 격리 픽스처. $1=레인 이름. 호출자가 $FX·$GH_LOG를 받는다.
# ⚠️ `run fx_new …`로 부르지 말 것 — 서브셸이라 변수 할당이 호출자에게 안 보인다
#    (test_tf-r2-init.bats가 실측으로 밟은 자리: 빈 $FX가 열거를 0건으로 만들어 공허하게 초록).
fx_new() {
  FX="$BATS_TEST_TMPDIR/fx.$1"
  rm -rf "$FX"
  mkdir -p "$FX/bin" "$FX/repo/apps/demo/deploy/prod"
  GH_LOG="$FX/gh.log"
  : > "$GH_LOG"
  # gh 스텁: argv만 기록한다(PR 생성 여부의 증인).
  printf '#!/usr/bin/env bash\nprintf "gh %%s\\n" "$*" >> "$GH_LOG"\n' > "$FX/bin/gh"
  chmod +x "$FX/bin/gh"
  # **마커 구간이 아니라 본문 전체**를 뽑는다 — 잔여물 블록까지 같이 돌아가므로 두 번째 추출기가 안 생긴다.
  yq -r '.runs.steps[0].run' "$A" > "$FX/body.sh"
  [ -s "$FX/body.sh" ]   # 추출 붕괴 바닥값 — 빈 본문이면 아래 레인이 통째로 공허해진다
  printf 'fixture pr body\n' > "$FX/pr-body.md"
  printf 'v1\n' > "$FX/repo/apps/demo/deploy/prod/values.yaml"
  git -c init.defaultBranch=main init --quiet --bare "$FX/origin"
  git -c init.defaultBranch=main init --quiet "$FX/repo"
  (
    cd "$FX/repo" || exit 1
    git add -A
    git -c user.name=ci -c user.email=ci@homelab.test commit -qm "fixture init"
    git remote add origin "$FX/origin"
  )
}

# action의 run 본문을 픽스처 repo에서 실제로 실행한다. $1=branch $2=add-paths $3=skip-if-empty
run_body() {
  (
    cd "$FX/repo" || exit 1
    PATH="$FX/bin:$PATH" GH_LOG="$GH_LOG" GITHUB_OUTPUT="$FX/github_output" \
      GH_TOKEN=stub BRANCH="$1" ADD_PATHS="$2" MSG="chore: 픽스처 변경" \
      PR_TITLE="fixture" PR_BODY="$FX/pr-body.md" AUTO_MERGE=false SKIP_IF_EMPTY="$3" \
      bash "$FX/body.sh"
  )
}

@test "the composite still has exactly one run step (the fixture executes steps[0])" {
  # 스텝이 하나라는 것이 아래 두 레인의 전제다 — 늘리면 파생이 증인 밖으로 샌다.
  # (선례: tools/tests/test_tf-r2-init.bats의 같은 등식.)
  [ "$(yq -r '.runs.steps | length' "$A")" -eq 1 ]
  [ "$(yq -r '.runs.steps[0].id' "$A")" = "commit" ]
}

@test "skip-if-empty yields result=noop and opens no PR when nothing is staged" {
  fx_new noop
  run run_body "fixture/noop" "apps/demo/deploy/prod/values.yaml" "true"
  [ "$status" -eq 0 ]
  [ -f "$FX/github_output" ]
  grep -qx 'result=noop' "$FX/github_output"
  # PR 부재 증인. 양성 대조는 아래 pr 레인이다 — 같은 스텁·같은 로그 파일이 거기서는 채워진다
  # (스텁이 죽으면 이 줄만으로는 '호출 안 함'과 '스텁이 안 돈다'를 구별하지 못한다).
  [ ! -s "$GH_LOG" ]
  # 브랜치를 만들지도 않았다 — origin에 아무것도 안 갔다.
  run git --git-dir="$FX/origin" rev-parse --verify --quiet "refs/heads/fixture/noop"
  [ "$status" -ne 0 ]
}

@test "a change inside the add-paths ceiling commits, pushes and opens a PR (result=pr)" {
  fx_new pr
  printf 'v2\n' > "$FX/repo/apps/demo/deploy/prod/values.yaml"
  run run_body "fixture/pr" "apps/demo/deploy/prod/values.yaml" "true"
  [ "$status" -eq 0 ]
  grep -qx 'result=pr' "$FX/github_output"
  # gh 스텁 로그가 PR 생성의 증인이자 위 레인의 양성 대조다.
  grep -q 'pr create' "$GH_LOG"
  # commit·push가 실제로 났다 — 쓰기 본체를 통째로 지우는 뮤테이션(B)이 여기서 red다.
  run git --git-dir="$FX/origin" rev-parse --verify --quiet "refs/heads/fixture/pr"
  [ "$status" -eq 0 ]
  # AUTO_MERGE=false라 auto-merge arm은 돌지 않는다(무장 축은 test_automerge-fallback.bats 소관).
  run grep -c 'pr merge' "$GH_LOG"
  [ "$output" -eq 0 ]
}

@test "every consumer compares only result literals the composite can emit" {
  # 출력값 리네임이 알림을 거짓말하게 만드는 자리를 막는다(값싼 정적 대조).
  emitted="$(grep -oE 'result=[a-z]+' "$A" | sed 's/^result=//' | LC_ALL=C sort -u)"
  [ -n "$emitted" ]                                   # 추출 붕괴 바닥값
  [ "$(printf '%s\n' "$emitted" | tr '\n' ' ')" = "noop pr " ]
  # 소비처 열거 — 5개 변이 reusable이 이 composite를 쓴다.
  run grep -rlF 'uses: ./.github/actions/pr-first-commit' "$WF"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 5 ]
  compared=0
  for wf in "$WF"/*.yaml; do
    id="$(yq -r '[.jobs[] | .steps[]? | select(.uses == "./.github/actions/pr-first-commit") | .id] | .[0] // ""' "$wf")"
    [ -n "$id" ] || continue
    while IFS= read -r lit; do
      [ -n "$lit" ] || continue
      compared=$((compared + 1))
      printf '%s\n' "$emitted" | grep -qx -- "$lit"
    done < <(grep -oE "steps\.$id\.outputs\.result == '[a-z]+'" "$wf" | grep -oE "'[a-z]+'" | tr -d "'" | LC_ALL=C sort -u)
  done
  # 열거 붕괴 바닥값 — _update-secrets.yaml이 noop·pr 둘 다 비교한다.
  [ "$compared" -ge 2 ]
}
