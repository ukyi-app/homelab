#!/usr/bin/env bats
# bump-poll **호출부 계약** — 원격 변이(브랜치 push·PR 생성·auto-merge 무장)는 오직 tools/ensure-bump-pr.ts를
# 통해서만.
#
# 왜 이 게이트가 필요한가(plan r2 R-4): ensure-bump-pr가 아무리 옳게 판정해도, 워크플로가 도구를
# 부르기 **전에** 스스로 push/create를 하면 프로덕션은 그대로 중복 PR을 낸다(도구만 GREEN). 순서·부작용
# 계약을 프로덕션 호출부에 못 박아야 그 false-green이 닫힌다.
#   ① `gh pr create` 직접 호출 0 — PR 생성은 도구가 관측(gh pr list + git ls-remote) 뒤에만 한다.
#   ② `git push` 직접 호출 0 — skip 판정이 "아무것도 변이하지 않음"이 되려면 push도 도구 몫이어야 한다.
#      (워크플로가 먼저 push하면: 판정이 skip이어도 원격 브랜치가 갱신되고, `gh pr create` 실패 시엔
#       **고아 원격 브랜치**가 남아 다음 주기 plain push와 non-fast-forward 충돌 → 배포 정지.)
#   ③ 브랜치명에 RUN_ID 없음 — run마다 브랜치가 달라지면 "이 bump의 열린 PR"을 조회할 대상 자체가 없다.
#   ④ **순서**(plan r4 R-8): 브랜치 생성 → bump-tag → commit → ensure-bump-pr. 도구는 "호출부가 브랜치를
#      최신 main에서 재구축해 **로컬 커밋을 얹어 둔** 상태"를 전제로 `HEAD`를 민다(push argv 계약의 소스가
#      HEAD다). 커밋 전에 도구를 부르면 빈 커밋(=main과 동일)을 밀어 PR이 diff 0으로 열리고, bump-tag 전에
#      부르면 갱신 자체가 빠진다 — 둘 다 "테스트는 GREEN, 배포는 무동작"이다. ①②③만으론 순서가 안 잡힌다.
#   ⑤ **auto-merge 독점**(plan r4 R-8): 워크플로는 `scripts/auto-merge-or-fail.sh`를 **직접 부르지 않는다**.
#      auto-merge는 실행기가 **PR을 실제로 만든 직후에만** 무장한다(--auto-merge). 워크플로가 따로 부르면
#      skip/rebuild 판정(=PR 생성 없음)에도 머지가 무장돼, 남의 PR이나 옛 PR을 건드릴 수 있다(이중 auto-merge).
#      ⚠️ 이 금지는 **bump-poll.yaml 파일 안에서만**이다 — 스크립트 자체는 bump.yaml·pr-first-commit
#      composite·ensure-bump-pr.ts가 계속 쓴다(아래 보존 증인이 그걸 고정한다).
#
# ── 구현자 가이드(이 파일의 회귀 증인들이 GREEN이 되려면 bump 스텝이 이렇게 생겨야 한다) ────────────
#   git checkout main
#   branch="bump-poll/${app}-${tag}"          # ③ RUN_ID 금지 — tag가 bump의 정체성이다
#   git checkout -b "$branch"                 # ④-1 브랜치 생성(최신 main에서 재구축)
#   bun tools/bump-tag.ts "$app" "$tag" --digest "$digest" --expect-current "$expect" [--pin "$pin"]  # ④-2
#   git add "$writePath" platform/victoria-stack/prod/digest-exporter.yaml
#   git commit -m "chore: ${app} 이미지를 ${tag}(digest 핀)로 갱신 (GHCR 폴링)"                        # ④-3
#   bun tools/ensure-bump-pr.ts --app "$app" --tag "$tag" \
#     --title … --body … $( [ "$action" = "bump" ] && echo --auto-merge )                             # ④-4, ⑤
#   # ⑤ `git push`·`gh pr create`·`bash scripts/auto-merge-or-fail.sh`는 이 스텝에 **남지 않는다**.
#
# 회귀(test_tags=regression): 지금은 RED(워크플로가 아직 옛 방식 — 직접 push + 직접 gh pr create + RUN_ID
# + auto-merge 직접 호출, 그리고 ensure-bump-pr 호출 자체가 없다).
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]]·중간 `!`는 침묵 통과.
# ⚠️ @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  F="$ROOT/.github/workflows/bump-poll.yaml"
  # 전체-줄 주석을 **빈 줄로 치환**한 뷰(줄 번호는 보존) — 주석 속 설명 문구("…auto-merge-or-fail…",
  # "…bump-tag.ts가 재검증한다" 등)가 순서·금지 증인에 오탐되는 걸 막는다(test_mutation-dispatch의 선례).
  CODE="$BATS_TEST_TMPDIR/bump-poll.code.yaml"
  sed 's/^[[:space:]]*#.*$//' "$F" > "$CODE"
}

# 주석 제거 뷰에서 ERE가 처음 등장한 줄 번호(없으면 빈 문자열 → 단언이 [ -n ]로 잡는다).
first_line() { grep -nE "$1" "$CODE" | head -1 | cut -d: -f1; }

# bats test_tags=regression
@test "bump-poll never calls gh pr create directly (PR creation goes through ensure-bump-pr)" {
  run grep -n "gh pr create" "$CODE"
  if [ "$status" -eq 0 ]; then
    echo "duplicate bump PR: bump-poll.yaml still calls 'gh pr create' directly — PR 생성은 tools/ensure-bump-pr.ts(조회→결정→변이)를 통해서만"
    echo "$output"
    false
  fi
}

# bats test_tags=regression
@test "bump-poll never pushes the bump branch directly (a skip decision must mutate nothing)" {
  run grep -nE '(^|[^-[:alnum:]])git push' "$CODE"
  if [ "$status" -eq 0 ]; then
    echo "orphan bump branch: bump-poll.yaml still runs 'git push' itself — push는 ensure-bump-pr가 관측 뒤에 (lease와 함께) 해야 한다"
    echo "$output"
    false
  fi
}

# bats test_tags=regression
@test "bump-poll drives the PR step through tools/ensure-bump-pr.ts" {
  run grep -n "tools/ensure-bump-pr.ts" "$CODE"
  if [ "$status" -ne 0 ]; then
    echo "duplicate bump PR: bump-poll.yaml이 tools/ensure-bump-pr.ts를 호출하지 않는다 — 멱등 실행기가 배선되지 않으면 도구 GREEN이 프로덕션을 고치지 못한다"
    false
  fi
}

# bats test_tags=regression
@test "the bump branch name carries no RUN_ID (same bump converges to one branch)" {
  run grep -n "RUN_ID" "$CODE"
  if [ "$status" -eq 0 ]; then
    echo "duplicate bump PR: bump-poll.yaml still derives the branch from RUN_ID — 같은 bump가 run마다 다른 브랜치를 만들어 조회 대상이 사라진다"
    echo "$output"
    false
  fi
}

# bats test_tags=regression
@test "the bump step creates the branch, bumps the tag, commits, and only then calls ensure-bump-pr (in that order)" {
  # plan r4 R-8: ①②③은 "도구를 부른다"까지만 본다 — **언제** 부르는지는 안 본다. 그래서 커밋 전에(또는
  # bump-tag 전에) 도구를 부르는 구현도 GREEN이 된다. 그런 호출부는 라이브에서 diff 0짜리 PR을 열거나
  # (빈 커밋) 갱신을 통째로 빠뜨린다 — 도구의 push argv 계약이 `HEAD:refs/heads/<b>`(=로컬 커밋)이기 때문.
  branch_at="$(first_line 'git (switch -c|checkout -b)')"
  bump_at="$(first_line 'bun tools/bump-tag\.ts')"
  commit_at="$(first_line 'git commit')"
  ensure_at="$(first_line 'bun tools/ensure-bump-pr\.ts')"

  [ -n "$branch_at" ] || { echo "호출부 순서 계약: 브랜치 생성(git switch -c | git checkout -b)이 없다"; false; }
  [ -n "$bump_at" ]   || { echo "호출부 순서 계약: bun tools/bump-tag.ts 호출이 없다"; false; }
  [ -n "$commit_at" ] || { echo "호출부 순서 계약: git commit이 없다"; false; }
  [ -n "$ensure_at" ] || {
    echo "호출부 순서 계약: bun tools/ensure-bump-pr.ts 호출이 없다 — 실행기가 배선돼야 순서를 증명할 수 있다"
    echo "  기대 순서: git checkout -b → bun tools/bump-tag.ts → git commit → bun tools/ensure-bump-pr.ts"
    false
  }

  [ "$branch_at" -lt "$bump_at" ] || {
    echo "호출부 순서 계약 위반: bump-tag(줄 $bump_at)가 브랜치 생성(줄 $branch_at)보다 앞선다 — main 위에서 값이 바뀐다"
    false
  }
  [ "$bump_at" -lt "$commit_at" ] || {
    echo "호출부 순서 계약 위반: git commit(줄 $commit_at)이 bump-tag(줄 $bump_at)보다 앞선다 — 갱신 없는 빈 커밋"
    false
  }
  [ "$commit_at" -lt "$ensure_at" ] || {
    echo "호출부 순서 계약 위반: ensure-bump-pr(줄 $ensure_at)가 git commit(줄 $commit_at)보다 앞선다 —"
    echo "  도구는 HEAD(=로컬 커밋)를 민다. 커밋 전에 부르면 main과 동일한 HEAD를 밀어 diff 0짜리 PR이 열린다."
    false
  }
}

# bats test_tags=regression
@test "auto-merge is armed only by ensure-bump-pr (bump-poll never runs the shared script itself)" {
  # plan r4 R-8: 워크플로에 직접 호출이 남아 있으면, 도구가 skip/rebuild(=PR 생성 0)를 판정한 주기에도
  # 워크플로가 auto-merge를 무장한다 → 옛 PR/남의 PR에 머지가 걸리는 **이중 auto-merge**. auto-merge는
  # "지금 막 내가 만든 PR"에만 붙어야 한다 = 실행기 안(PR 생성 직후)이 유일한 자리다.
  run grep -nE 'auto-merge-or-fail\.sh' "$CODE"
  if [ "$status" -eq 0 ]; then
    echo "double auto-merge: bump-poll.yaml still runs 'scripts/auto-merge-or-fail.sh' itself —"
    echo "  auto-merge는 tools/ensure-bump-pr.ts가 PR을 **실제로 만든 직후에만** 무장한다(--auto-merge)."
    echo "  skip/rebuild 판정(PR 생성 0)에도 무장되면 옛 PR이 머지될 수 있다."
    echo "$output"
    false
  fi
  # 무장 자체가 사라지면 안 된다(autoDeploy 레인은 여전히 자동 머지) → 도구에 --auto-merge를 넘긴다.
  run grep -nE -- '--auto-merge' "$CODE"
  if [ "$status" -ne 0 ]; then
    echo "lost auto-merge: bump-poll.yaml이 ensure-bump-pr에 --auto-merge를 넘기지 않는다 —"
    echo "  autoDeploy(action=bump) 레인은 자동 머지가 계약이다(승인 레인=propose-pr은 사람 머지)."
    false
  fi
}

# ---------------------------------------------------------------------------
# 보존 — 재작성이 기존 계약(플래너·TOCTOU 가드·공유 auto-merge 스크립트)을 깨지 않았음을 확인(지금도 GREEN)
# ---------------------------------------------------------------------------

@test "bump-poll still plans with poll-ghcr and re-proves the from-tag via bump-tag --expect-current" {
  run grep -q "tools/poll-ghcr.ts" "$F"
  [ "$status" -eq 0 ]
  run grep -qE 'bump-tag\.ts .*--expect-current' "$F"
  [ "$status" -eq 0 ]
}

@test "the auto-merge ban is scoped to bump-poll.yaml (the shared script keeps its other callers)" {
  # ⑤의 금지는 **파일 스코프**다 — scripts/auto-merge-or-fail.sh는 삭제 대상이 아니다.
  # bump-poll 레인의 auto-merge는 사라지는 게 아니라 **실행기 안으로 옮겨간다**(PR 생성 직후 1회).
  run grep -q 'auto-merge-or-fail\.sh' "$ROOT/scripts/auto-merge-or-fail.sh"
  [ "$status" -eq 0 ]
  run grep -q 'auto-merge-or-fail\.sh' "$ROOT/.github/workflows/bump.yaml"
  [ "$status" -eq 0 ]
  run grep -q 'auto-merge-or-fail\.sh' "$ROOT/.github/actions/pr-first-commit/action.yml"
  [ "$status" -eq 0 ]
  run grep -q 'auto-merge-or-fail\.sh' "$ROOT/tools/ensure-bump-pr.ts"
  [ "$status" -eq 0 ]
}
