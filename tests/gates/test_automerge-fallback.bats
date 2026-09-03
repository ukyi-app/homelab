#!/usr/bin/env bats
# races-6: auto-merge fallback이 un-gated 직접 머지를 분기보호에만 의존하지 않게 — 이미 CLEAN인
# PR에서만 직접 squash하고, 그 외(BLOCKED/BEHIND/UNKNOWN)는 시끄럽게 실패한다.
# ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과). @test 이름은 영어.

# ⚠️ **피연산자 실재 증인 + 거부 문구 양성 대조.** 스크립트가 없으면 `run bash "$S"`가 rc **127**로
#    죽어 `-ne 0` 단독 레인을 통과시킨다. 실측(2026-09-02, `scripts/auto-merge-or-fail.sh`를 지운 격리 트리):
#    6건 중 「requires a branch argument」가 `ok`였다.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  S="$ROOT/scripts/auto-merge-or-fail.sh"
  [ -f "$S" ]
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"; mkdir -p "$BIN"
  LOG="$TMP/gh.log"
  # gh stub: 인자/서브커맨드를 LOG에 기록. mergeStateStatus는 $GH_STATE로 주입.
  cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$LOG"
case "\$*" in
  *"pr view"*"mergeStateStatus"*) printf '%s' "\${GH_STATE:-CLEAN}"; exit 0 ;;
  *"pr merge --auto"*) exit "\${GH_AUTO_RC:-1}" ;;   # --auto는 이미 clean PR엔 에러(라이브 계약) → 기본 실패
  *"pr merge --squash"*) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
}
teardown() { rm -rf "$TMP"; }

@test "auto-merge arms via --auto and never falls back when --auto succeeds" {
  GH_AUTO_RC=0 run bash "$S" mybranch
  [ "$status" -eq 0 ]
  grep -q "pr merge --auto --squash mybranch" "$LOG"
  # --auto 성공 시 직접 머지(--squash 단독)는 호출되지 않는다
  run grep -c "pr merge --squash mybranch" "$LOG"
  [ "$output" -eq 0 ]
}

@test "falls back to a direct squash ONLY when the PR is already CLEAN" {
  GH_AUTO_RC=1 GH_STATE=CLEAN run bash "$S" mybranch
  [ "$status" -eq 0 ]
  grep -q "pr view mybranch" "$LOG"
  grep -q "pr merge --squash mybranch" "$LOG"
}

@test "fails loudly (does not direct-merge) when --auto fails and PR is BLOCKED" {
  GH_AUTO_RC=1 GH_STATE=BLOCKED run bash "$S" mybranch
  [ "$status" -ne 0 ]
  # un-gated 직접 머지는 절대 시도하지 않는다
  run grep -c "pr merge --squash mybranch" "$LOG"
  [ "$output" -eq 0 ]
  echo "$output" "$status"
}

@test "fails loudly when PR is BEHIND (must update-branch first, not direct-merge)" {
  GH_AUTO_RC=1 GH_STATE=BEHIND run bash "$S" mybranch
  [ "$status" -ne 0 ]
  run grep -c "pr merge --squash mybranch" "$LOG"
  [ "$output" -eq 0 ]
}

@test "requires a branch argument" {
  run bash "$S"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'branch 인자 필수'
}

@test "all auto-merge callsites use the shared script, not the raw OR-fallback" {
  WF="$ROOT/.github/workflows"
  A="$ROOT/.github/actions"
  # races-6: un-gated 직접 머지 OR-폴백 박멸 — 공유 스크립트만 호출한다.
  # ⚠️ 스캔 표면에 `$A`(액션 디렉토리)가 함께 들어간다 — 워크플로만 훑던 판은 raw 폴백이
  #    **composite 안으로 되돌아와도** 이 게이트의 1차 불변식조차 침묵했다(실측: .github/actions 0건).
  raw=$(grep -rn 'gh pr merge --auto --squash "\$branch" || gh pr merge --squash' "$WF" "$A" || true)
  [ -z "$raw" ]
  # 변이 reusable의 auto-merge는 pr-first-commit composite로 수렴(B6) — 스크립트는 composite에서 1회 호출.
  # ⚠️ **커맨드 줄에 앵커한다.** 앵커 없는 substring grep은 이 액션의 헤더 주석(:3)과 입력
  #    description(:14)에 매치한다 — 실제 arm 블록(`if [ "$AUTO_MERGE" = "true" ]; …`)을 통째로
  #    지워도 6/6 전건 초록이었다(2026-09-03 뮤테이션 실측). 규약을 성실히 문서화한 파일이 그
  #    문서로 자기 자신을 증명하던 자리다(traps 「면제 판정이 주석보다 먼저 돌면…」·「프로브는 호출이 아니다」).
  # ⚠️ 여기서 주석 제거 뷰 관용구(test_pr-sweeper.bats:96-99)는 듣지 않는다 — :14는 주석이 아니라
  #    YAML input description이라 스트립을 통과한다. 개수 앵커(`-c … -eq 3`)도 금지: 산문 편집이 red를 낸다.
  run grep -Eq '^[[:space:]]*bash scripts/auto-merge-or-fail\.sh' "$A/pr-first-commit/action.yml"
  [ "$status" -eq 0 ]
  # 직접 호출은 bump.yaml(비-변이 reconciler)에만 잔존.
  grep -q 'auto-merge-or-fail.sh' "$WF/bump.yaml" || { echo "missing shared fallback in bump.yaml"; false; }
  # ⚠️ bump-poll 레인은 **파일이 아니라 도구**가 소유한다(plan r4 R-8): auto-merge는 tools/ensure-bump-pr.ts
  # 안에서만, **레인이 bump일 때만**(`--action bump` — autoDeploy) 무장한다(plan r5 R-11: 무장을 켜는 별도
  # 플래그는 없다). 워크플로가 따로 부르면 skip/rebuild 판정(PR 생성 0)에도 무장돼 옛 PR이 머지될 수 있다 →
  # bump-poll.yaml 안의 직접 호출은 tests/gates/test_bump-poll-callsite.bats가 금지한다.
  # 여기서는 그 레인이 **여전히 공유 스크립트를 쓴다**는 사실만 고정한다(raw OR-폴백 박멸이 이 게이트의 불변식).
  grep -q 'auto-merge-or-fail.sh' "$ROOT/tools/ensure-bump-pr.ts" || { echo "missing shared fallback in tools/ensure-bump-pr.ts"; false; }
  # 변이 reusable은 composite 위임이라 직접 호출 0(auto-merge: 'true'/'false' 입력만).
  run grep -l 'auto-merge-or-fail.sh' "$WF"/_create-database.yaml "$WF"/_create-cache.yaml "$WF"/_update-secrets.yaml "$WF"/_create-app.yaml "$WF"/_teardown-app.yaml
  # rc 2(파일 하나라도 부재)를 통과로 읽지 않는다 — 다중 피연산자 grep의 무매치는 정확히 rc 1이다.
  [ "$status" -eq 1 ]
  # bump.yaml은 단일 job(writeback) — 1회 호출 (v1 외부 dispatch 경로 폐기)
  run grep -c 'auto-merge-or-fail.sh' "$WF/bump.yaml"
  [ "$output" -eq 1 ]
}
