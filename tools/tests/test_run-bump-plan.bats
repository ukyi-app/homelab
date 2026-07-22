#!/usr/bin/env bats
# run-bump-plan.ts(F-1 항목 러너)의 실행 테스트 — **진짜 git worktree fixture** + ensure-bump-pr **stub**.
# 러너의 유일 주장(worktree 공간 격리로 R-38·H-2 누출 소멸)을 실제 git으로 태운다. 원격(ensure-bump-pr)만 stub한다.
# stub은 cwd=worktree(HEAD=bump 커밋)에서 돌며 argv + 브랜치/author/커밋파일을 원장에 기록 → 러너의 per-item 결과를 증인화.
# ⚠️ 중간 단언은 `[ ]`만(bash 3.2 set -e가 `[[ ]]` 실패를 침묵 통과) · 중간 부정은 `run …; [ "$status" -ne 0 ]`.

DIG="sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"

seed_repo() {  # 2앱(page·trip-mate) values + digest-exporter를 가진 진짜 git repo(main)
  REPO="$(mktemp -d)"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.name seed
  git -C "$REPO" config user.email seed@t
  for app in page trip-mate; do
    mkdir -p "$REPO/apps/$app/deploy/prod"
    printf 'image:\n  repo: ghcr.io/ukyi-app/%s\n  tag: sha-0000000\nkind: web\n' "$app" > "$REPO/apps/$app/deploy/prod/values.yaml"
  done
  mkdir -p "$REPO/platform/victoria-stack/prod"
  printf 'apiVersion: apps/v1\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - name: digest-exporter\n          env:\n            - name: APPS\n              value: "page=ghcr.io/ukyi-app/page:sha-0000000 trip-mate=ghcr.io/ukyi-app/trip-mate:sha-0000000"\n' > "$REPO/platform/victoria-stack/prod/digest-exporter.yaml"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m init
  # ensure-bump-pr stub: cwd=worktree(HEAD=bump 커밋). argv + 커밋 상태(브랜치·author·파일)를 원장에 기록.
  LEDGER="$REPO/ensure-ledger"; : > "$LEDGER"; export LEDGER
  cat > "$REPO/ensure-stub.sh" <<'EOF'
{ echo "=== call ==="
  echo "argv: $*"
  echo "branch: $(git rev-parse --abbrev-ref HEAD 2>&1)"
  echo "author: $(git log -1 --format='%an <%ae>' 2>&1)"
  echo "files: $(git show --name-only --format= HEAD 2>&1 | tr '\n' ' ')"
} >> "$LEDGER"
exit "${ENSURE_EXIT:-0}"
EOF
}

teardown() { [ -n "${REPO:-}" ] && rm -rf "$REPO"; }

plan_json() {  # $1=page action, $2=trip-mate action, [$3=page current.tag override]
  local pc="${3:-sha-0000000}"
  cat > "$REPO/plan.json" <<EOF
[
 {"app":"page","action":"$1","candidate":{"tag":"sha-deadbee","digest":"$DIG"},"current":{"tag":"$pc"},"writePath":"apps/page/deploy/prod/values.yaml"},
 {"app":"trip-mate","action":"$2","candidate":{"tag":"sha-feedbee","digest":"$DIG"},"current":{"tag":"sha-0000000"},"writePath":"apps/trip-mate/deploy/prod/values.yaml"}
]
EOF
}

run_runner() {  # $1=ENSURE_EXIT(기본 0)
  run env ENSURE_EXIT="${1:-0}" LEDGER="$REPO/ensure-ledger" \
    bun tools/run-bump-plan.ts --plan "$REPO/plan.json" --repo-root "$REPO" \
      --ensure-bin bash --ensure-script "$REPO/ensure-stub.sh"
}

no_leftover() {  # 정리 teeth: main worktree만 남고 bump-poll 로컬 브랜치 0
  run bash -c "git -C '$REPO' worktree list | wc -l | tr -d ' '"
  [ "$output" = "1" ]
  run bash -c "git -C '$REPO' branch --list 'bump-poll/*'"
  [ -z "$output" ]
}

@test "each item commits its own writePath+digest-exporter with writer identity, on its own branch, and calls ensure with the planner's lane verbatim" {
  seed_repo; plan_json bump propose-pr; run_runner 0
  [ "$status" -eq 0 ]
  # page: bump 레인 · 브랜치 · writer identity · 자기 파일만 (grep -qF 중간 단언 = ERR-trap이 실패를 잡는다)
  page="$(grep -A4 'argv: --app page --tag sha-deadbee' "$LEDGER")"
  grep -qF -- "--action bump" <<<"$page"
  grep -qF "branch: bump-poll/page-sha-deadbee" <<<"$page"
  grep -qF "ukyi-homelab-writer[bot]" <<<"$page"
  grep -qF "apps/page/deploy/prod/values.yaml" <<<"$page"
  grep -qF "platform/victoria-stack/prod/digest-exporter.yaml" <<<"$page"
  # trip-mate: propose-pr 레인 verbatim(재해석 없음)
  tm="$(grep -A1 'argv: --app trip-mate' "$LEDGER")"
  grep -qF -- "--action propose-pr" <<<"$tm"
  no_leftover
}

@test "H-2: an item that fails AFTER git add leaves no residue in the next item's commit (spatial isolation contains staged residue)" {
  seed_repo
  # pre-commit 훅: staged에 apps/page/가 있으면 실패(= page는 git add 후 commit에서 실패, staged 잔여 남김)
  printf '#!/usr/bin/env bash\ngit diff --cached --name-only | grep -q "^apps/page/" && { echo "hook: page commit 차단"; exit 1; }\nexit 0\n' > "$REPO/.git/hooks/pre-commit"
  chmod +x "$REPO/.git/hooks/pre-commit"
  plan_json bump bump; run_runner 0
  [ "$status" -ne 0 ]                       # page 실패 → run 비-0
  run grep -c "argv: --app page" "$LEDGER"  # page는 commit 실패로 ensure 미도달
  [ "$output" = "0" ]
  # trip-mate의 commit은 자기 파일만 — page의 staged writePath·digest-exporter 잔여가 **누출되지 않음**(격리 teeth)
  tm="$(grep -A4 'argv: --app trip-mate' "$LEDGER")"
  grep -qF "apps/trip-mate/deploy/prod/values.yaml" <<<"$tm"
  run grep -qF "apps/page/" <<<"$tm"        # 누출됐다면 여기서 status 0 → 아래 -ne 0이 RED(격리 teeth)
  [ "$status" -ne 0 ]
  no_leftover                               # 실패 경로에서도 worktree/브랜치 누적 0
}

@test "an item whose bump-tag fails BEFORE staging is fail-closed and never reaches ensure; other items continue" {
  seed_repo; plan_json bump bump sha-WRONGXX   # page expect-current 불일치 → bump-tag fail-closed(add 전)
  run_runner 0
  [ "$status" -ne 0 ]
  run grep -c "argv: --app page" "$LEDGER"     # 순서 계약: bump-tag 실패 시 ensure 미호출
  [ "$output" = "0" ]
  run grep -c "argv: --app trip-mate" "$LEDGER" # 나머지는 계속(굶김 없음)
  [ "$output" = "1" ]
  no_leftover
}

@test "a stubbed ensure-bump-pr failure is aggregated fail-closed (run red) without starving the other item" {
  seed_repo; plan_json bump bump; run_runner 1   # 모든 ensure 실패
  [ "$status" -ne 0 ]
  run grep -c "=== call ===" "$LEDGER"           # 두 항목 모두 ensure까지 도달(굶김 없음)
  [ "$output" = "2" ]
  no_leftover
}

@test "the runner performs no direct remote mutation — it runs with no git remote and still succeeds (push/PR is ensure-bump-pr's alone)" {
  seed_repo   # fixture에 origin 없음 — 러너가 직접 push하면 실패했을 것
  plan_json bump bump; run_runner 0
  [ "$status" -eq 0 ]   # ensure(stub)만이 원격 경로 → 러너 직접 push 0
  no_leftover
}

@test "only bump/propose-pr items are processed (skip/refuse are filtered out)" {
  seed_repo
  cat > "$REPO/plan.json" <<EOF
[ {"app":"page","action":"skip","candidate":{"tag":"sha-deadbee","digest":"$DIG"},"current":{"tag":"sha-0000000"},"writePath":"apps/page/deploy/prod/values.yaml"},
  {"app":"trip-mate","action":"bump","candidate":{"tag":"sha-feedbee","digest":"$DIG"},"current":{"tag":"sha-0000000"},"writePath":"apps/trip-mate/deploy/prod/values.yaml"} ]
EOF
  run_runner 0
  [ "$status" -eq 0 ]
  run grep -c "argv: --app page" "$LEDGER"     # skip은 처리 안 함
  [ "$output" = "0" ]
  run grep -c "argv: --app trip-mate" "$LEDGER"
  [ "$output" = "1" ]
}
