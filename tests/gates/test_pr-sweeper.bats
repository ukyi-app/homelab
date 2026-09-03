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
  # 트리거 집합 상한 — @test 이름의 'only'를 여기서 못박는다(push/pull_request_target/issue_comment
  # 등 추가 시 red). 위 두 존재 단언은 원소 제거만 잡고 추가 방향은 이 등식이 잡는다.
  [ "$(yq -r '.on | keys | sort | join(",")' "$F")" = "schedule,workflow_dispatch" ]
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

# ── 무장 초크포인트 스캔의 도구 ────────────────────────────────────────────────────────────────
# 스위퍼의 **라이브** head 접두 union을 워크플로에서 뽑는다. 문자열 대조가 아니라 실제로 **실행**하기
# 위해서다(관용구 선례: tests/gates/test_bump-poll-callsite.bats:570 — 앵커를 풀거나 대안을 넓혀도
# 문자열 증인은 통과하지만 라이브 동작은 달라진다). 못 뽑으면 빈 문자열을 낸다: 셀렉터 줄을 통째로
# 지우는 뮤테이션이 이 경로로 red가 된다.
sweeper_union_re() {
  sel="$(grep -oE 'test\("[^"]+"\)' "$F" | head -1)"
  printf '%s' "$sel" | sed -E 's/^test\("//; s/"\)$//'
}

# 접두가 라이브 union에 선택되는가 — jq로 그 정규식을 **실제 브랜치명에 돌린다**(라이브 셀렉터가
# jq의 test()이므로 같은 엔진으로 잰다). 매치하면 브랜치명을, 아니면 빈 문자열을 출력한다.
probe_select() {
  printf '[{"h":"%s/probe-branch"}]' "$2" | jq -r --arg re "$1" '.[] | select(.h | test($re)) | .h'
}

@test "the sweeper union selects every arming producer's branch prefix (armed-chokepoint scan)" {
  # ★ 파생 우주는 `LANES`도 손 목록도 아니라 **무장 초크포인트 전수 스캔**이다. 스위퍼가 손대는 PR은
  #   `autoMergeRequest != null`(무장됨)뿐이므로, 지켜야 할 불변식은 **무장하는 생산자의 브랜치 접두는
  #   전부 union이 select한다**이다. 무장은 오늘 세 자리에서만 일어나고 그 우주는 닫혀 있다:
  #     ① `pr-first-commit` 소비자 중 `auto-merge: 'true'`
  #     ② `scripts/auto-merge-or-fail.sh` 직접 호출
  #     ③ `gh pr merge --auto` 직접 호출
  #   유일한 예외는 `bump-poll/`이고 근거는 pr-sweeper.yaml의 ★★ 블록에 산다(실행기 단일 소유).
  # ⚠️ 이 단언은 **단방향**이다 — union이 무장하지 않는 접두를 더 골라도 무해하다(무장 필터가 거른다).
  #   오늘 `create-app/`이 그 자리다. 반대 방향(무장했는데 미선택)만이 멈춘 PR을 만든다.
  command -v jq >/dev/null || skip "jq required"
  WFD="$ROOT/.github/workflows"
  [ -d "$WFD" ]

  re="$(sweeper_union_re)"
  [ -n "$re" ] || { echo "pr-sweeper.yaml에서 head 접두 union(test(\"…\"))을 뽑지 못했다 — 셀렉터가 사라졌다"; false; }

  # ── ① `pr-first-commit` 소비자 — 구조적 파생(손 목록 없음) ──────────────────────────────────
  consumers=0; armed=""
  for w in "$WFD"/*.yaml; do
    while IFS=$'\t' read -r am br; do
      [ -n "$br" ] || continue
      consumers=$((consumers + 1))
      if [ "$am" = "true" ]; then armed="$armed $(basename "$w")=${br%%/*}"; fi
    done < <(yq -r '.jobs[]?.steps[]? | select(.uses == "./.github/actions/pr-first-commit")
                    | [(.with."auto-merge" // "false"), .with.branch] | @tsv' "$w")
  done
  # 부분-실명 대책 겸 비공허 바닥값: yq 열거 수 == raw grep 수(test_telegram-callsites.bats:63-70 관용구).
  # 한쪽이 조용히 붕괴하면(스키마 변경·오타) 두 수가 어긋나 red다.
  raw="$(grep -rhoE 'uses:[[:space:]]*\./\.github/actions/pr-first-commit' "$WFD" | wc -l | tr -d ' ')"
  [ "$raw" -ge 1 ] || { echo "enumeration collapse: pr-first-commit 소비자 0곳 — 열거가 붕괴했다"; false; }
  [ "$consumers" -eq "$raw" ] || { echo "partial blindness: yq 열거 ${consumers} ≠ grep 열거 ${raw}"; false; }
  [ -n "$armed" ] || { echo "enumeration collapse: auto-merge 'true' 소비자 0곳 — 무장 집합이 비면 아래 전칭이 항진이다"; false; }

  # ── ②③ 직접 무장 호출부 — 주석 제거 뷰 전수 스캔 ────────────────────────────────────────────
  # 주석이 금지/설명 문구로 토큰을 담으므로(예: auto-merge-or-fail.sh:3, ensure-bump-pr.ts:1827)
  # 전체-줄 주석을 지운 뷰에서 본다(test_bump-poll-callsite.bats:606-616 · test_mutation-dispatch.bats:165 관용구).
  scanned=0; direct=""
  for f in "$WFD"/*.yaml "$ROOT"/.github/actions/*/action.yml "$ROOT"/scripts/*.sh "$ROOT"/tools/*.ts; do
    [ -e "$f" ] || continue
    scanned=$((scanned + 1))
    code="$BATS_TEST_TMPDIR/armed.view"
    case "$f" in
      *.ts) sed 's#^[[:space:]]*//.*$##' "$f" > "$code" ;;
      *)    sed 's/^[[:space:]]*#.*$//' "$f" > "$code" ;;
    esac
    if grep -qE 'auto-merge-or-fail\.sh|gh pr merge .*--auto([^-]|$)' "$code"; then
      direct="$direct ${f#"$ROOT"/}"
    fi
  done
  [ "$scanned" -ge 1 ] || { echo "enumeration collapse: ②③ 스캔 대상 0개 — 글롭이 붕괴했다"; false; }
  [ -n "$direct" ] || { echo "enumeration collapse: ②③ 무장 호출부 0곳 — 최소한 공유 스크립트 자신이 잡혀야 한다"; false; }

  # 발견된 호출부를 **생산자**와 **기전**으로 가른다. 표의 접두는 그 파일에서 실증하므로(아래 grep)
  # 네임스페이스를 리네임하면 표가 사실과 어긋나 red다. 표에 없는 파일은 곧 **계정되지 않은 무장 생산자**다.
  unaccounted=""
  for rel in $direct; do
    case "$rel" in
      # 기전 자체 — 자기 브랜치가 없다(무장할 브랜치는 호출부가 준다).
      .github/actions/pr-first-commit/action.yml) continue ;;   # 소비자는 ①이 이미 열거한다
      scripts/auto-merge-or-fail.sh)              continue ;;   # ③의 유일한 자리(패스스루 래퍼)
      # 생산자.
      .github/workflows/bump.yaml)                pfx="bump" ;;       # branch="bump/build-${RUN_ID}"
      tools/ensure-bump-pr.ts)                    pfx="bump-poll" ;;  # 문서화된 유일 예외(실행기 단일 소유)
      *) unaccounted="$unaccounted $rel"; continue ;;
    esac
    grep -q "$pfx/" "$ROOT/$rel" || { echo "표 드리프트: 접두 '$pfx/'가 $rel 안에 없다"; false; }
    armed="$armed $rel=$pfx"
  done
  [ -z "$unaccounted" ] || {
    echo "계정되지 않은 무장 생산자:$unaccounted"
    echo "  브랜치 접두를 판정해 이 표에 넣고, 예외가 아니라면 pr-sweeper.yaml의 head 접두 union에도 넣어라."
    echo "  넣지 않으면 그 접두의 무장된 PR이 BEHIND로 굳었을 때 아무도 전진시키지 않는다(멈춘 PR)."
    false
  }

  # ── `teardown/` 판정(의도된 부재) ───────────────────────────────────────────────────────────
  # ⓐ teardown 레인은 **무장하지 않는다**(_teardown-app.yaml `auto-merge: 'false'` · scripts/teardown.sh는
  #    PR을 무장하지 않는다 — 둘 다 이 스캔이 방금 확인했다). 그래서 스위퍼의 `autoMergeRequest != null`
  #    필터가 그 PR을 애초에 배제한다 = union에 넣어도 무의미하고, 빠져 있는 것이 **의도**다.
  #    ⚠️ 형제 증인: tools/tests/test_mutation-dispatch.bats의 "auto-merge policy is preserved per reusable"이
  #    같은 사실을 손 목록으로 못박는다. 여기 판정은 그 목록 밖의 생산자까지 덮는 파생 형태이고,
  #    아래 앵커(ⓑ)가 서려면 이 전제가 참이어야 하므로 같은 @test 안에 둔다.
  if printf '%s\n' $armed | sed 's/.*=//' | grep -qx teardown; then
    echo "정책 변경 감지: teardown 레인이 무장한다 — 파괴 PR의 auto-merge는 리뷰 대상이다(수동 머지 규약)."
    echo "  무장을 유지할 거라면 pr-sweeper.yaml의 union에 teardown/을 넣고 이 판정과 근거를 다시 써라."
    false
  fi

  # ── 불변식: 무장 접두 ⊆ 라이브 union (정규식을 실제로 실행해 판정한다) ─────────────────────
  for e in $armed; do
    pfx="${e##*=}"
    if [ "$pfx" = "bump-poll" ]; then
      # 유일한 예외. 미선택이라는 **동작**은 test_bump-poll-callsite.bats가 같은 정규식을 실행해 못박으므로
      # 여기서는 그 근거가 워크플로에 살아 있는지만 본다(근거 없는 예외 = 다음 리뷰의 오독).
      grep -q 'bump-poll/' "$F" || { echo "예외 근거 상실: pr-sweeper.yaml에 bump-poll/ 제외 근거가 없다"; false; }
      continue
    fi
    hit="$(probe_select "$re" "$pfx")"
    [ -n "$hit" ] || {
      echo "stalled PR: 무장 생산자 ${e%%=*}의 접두 '$pfx/'를 스위퍼 union이 고르지 않는다(union='$re')."
      echo "  그 레인의 PR은 무장된 채 BEHIND로 굳으면 아무도 update-branch하지 않아 영구 잔류한다(races-3/obs-5)."
      false
    }
  done

  # ── 앵커: union은 `.*`류가 아니다 ───────────────────────────────────────────────────────────
  # ⓑ 무장하지 않는 접두(`teardown/`)를 union이 고르지 않는다. 이 줄이 없으면 위 전칭은 union을
  #    catch-all로 뭉개는 것만으로 항진이 된다(실측: `test(".")`로 바꾸면 전칭은 통과하고 이 줄만 red다).
  hit="$(probe_select "$re" teardown)"
  [ -z "$hit" ] || { echo "anchor broken: union이 teardown/을 고른다(union='$re') — 앵커가 풀렸거나 정책이 바뀌었다"; false; }
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
