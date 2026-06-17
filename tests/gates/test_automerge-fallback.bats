#!/usr/bin/env bats
# races-6: auto-merge fallback이 un-gated 직접 머지를 분기보호에만 의존하지 않게 — 이미 CLEAN인
# PR에서만 직접 squash하고, 그 외(BLOCKED/BEHIND/UNKNOWN)는 시끄럽게 실패한다.
# ⚠️ 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵통과). @test 이름은 영어.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  S="$ROOT/scripts/auto-merge-or-fail.sh"
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
}

@test "all six auto-merge callsites use the shared script, not the raw OR-fallback" {
  WF="$ROOT/.github/workflows"
  # races-6: un-gated 직접 머지 OR-폴백을 6곳에서 박멸 — 공유 스크립트만 호출한다.
  raw=$(grep -rn 'gh pr merge --auto --squash "\$branch" || gh pr merge --squash' "$WF" || true)
  [ -z "$raw" ]
  for f in bump.yaml bump-poll.yaml _create-database.yaml _create-cache.yaml _update-secrets.yaml; do
    grep -q 'auto-merge-or-fail.sh' "$WF/$f" || { echo "missing shared fallback in $f"; false; }
  done
  # bump.yaml은 두 job(writeback/writeback-dispatch) — 2회 호출
  run grep -c 'auto-merge-or-fail.sh' "$WF/bump.yaml"
  [ "$output" -eq 2 ]
}
