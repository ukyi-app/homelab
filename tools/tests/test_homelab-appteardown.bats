#!/usr/bin/env bats
# homelab app teardown — 파괴 동사의 프로세스 경계 계약.
# 두 가지가 다른 동사들과 다르다:
#   1) confirm 가드 — `--confirm <app>`이 앱 이름과 정확히 일치해야 하고, 플래그가 없으면 TTY면
#      재입력 프롬프트·비-TTY면 거부다. 거부는 **디스패치 전**이라 원장에 gh 호출이 0건이어야 한다.
#   2) 종결 상태 — 삭제 대상 Application은 Healthy가 될 수 없다. 성공 = 머지 관측 + **Application 부재**
#      (appset finalizer cascade prune 완료). DNS 회수는 iac/tf-reconcile 소관이라 관측 대상이 아니다.
# TTY 경로는 pty(util-linux `script`)로 실물 터미널을 만들어 검증한다 — isTTY 자체를 주입 가능하게
# 만들면 프로덕션 코드에 테스트 전용 분기가 생기고, 정작 진짜 TTY 동작은 검증되지 않는다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(인코딩 함정).
bats_require_minimum_version 1.5.0
load "helpers/cli_stub"

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1
  cli_stub_init
  make_gh_stub
  make_kubectl_stub
  KC="$BATS_TEST_TMPDIR/kubeconfig"
  echo "apiVersion: v1" > "$KC"
  # 철거 PR — 기본은 미머지(수동 머지 = 파괴 승인).
  printf '[{"number":91,"html_url":"https://github.com/ukyi-app/homelab/pull/91","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/db-prs.json"
  # 머지된 철거 PR 픽스처(테스트가 db-prs.json에 덮어써서 쓴다).
  MERGED='[{"number":91,"html_url":"https://github.com/ukyi-app/homelab/pull/91","merged_at":"2026-08-24T09:00:00Z","merge_commit_sha":"feedbee"}]'
}

run_teardown() {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts app teardown myapp --poll-ms 10 --deadline-ms 500 "$@"
}

# pty 실행 — stdin에 한 줄을 흘려 넣고 실물 터미널에서 CLI를 돌린다. 종료코드는 script -e가 전파한다.
run_teardown_tty() {
  answer="$1"; shift
  run bash -c "printf '%s\n' '$answer' | script -qec \"env PATH='$STUB' KUBECONFIG='$KC' HOMELAB_CORRELATION='$NONCE' '$BUN' tools/homelab.ts app teardown myapp --poll-ms 10 --deadline-ms 500 $*\" /dev/null"
}

@test "app teardown dispatches app+confirm+correlation and reports the PR handle by default" {
  run_teardown --confirm myapp --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verb')" = "app teardown" ]
  [ "$(echo "$output" | jq -r '.result.action')" = "teardown-app" ]
  [ "$(echo "$output" | jq -r '.result.run.id')" = "901" ]
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "91" ]
  # DNS 회수는 이 동사의 관측 대상이 아니다 — 결과가 소관을 명시한다.
  [ "$(echo "$output" | jq -r '.result.dnsReclaim')" = "iac/tf-reconcile" ]
  run python3 "$LEDGER_PY" exact "$CALLS" gh workflow run teardown-app.yaml -R ukyi-app/homelab \
    -f "app=myapp" -f "confirm=myapp" -f "correlation=$NONCE"
  [ "$status" -eq 0 ]
}

@test "a confirm value that does not match the app name is refused with NO dispatch" {
  run_teardown --confirm otherapp --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
}

@test "a missing confirm flag on non-TTY stdin is refused with NO dispatch" {
  run_teardown --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
  echo "$stderr" | grep -q -- "--confirm"
}

@test "a TTY prompt proceeds only when the re-entered name matches" {
  # 일치 → 디스패치까지 간다(같은 argv 계약).
  run_teardown_tty myapp --json
  [ "$status" -eq 0 ]
  run python3 "$LEDGER_PY" exact "$CALLS" gh workflow run teardown-app.yaml -R ukyi-app/homelab \
    -f "app=myapp" -f "confirm=myapp" -f "correlation=$NONCE"
  [ "$status" -eq 0 ]
  # 불일치 → 새 원장에서 gh 호출 0건.
  : > "$CALLS"
  run_teardown_tty wrongname --json
  [ "$status" -eq 2 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
}

@test "wait on an unmerged teardown PR is a bounded human-merge pending and NO auto-merge argv exists" {
  run_teardown --confirm myapp --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "머지 대기"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "파괴 승인"
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "91" ]
  # 파괴 경계 단언: gh pr 계열(merge --auto 포함) argv가 원장에 하나도 없다
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh pr)" = "0" ]
}

@test "the terminal state is the ABSENCE of the Application, never Healthy" {
  printf '%s\n' "$MERGED" > "$FIX/db-prs.json"
  # 철거 머지는 표면(apps/myapp/...)을 제거한다 — 머지 SHA에서 표면 부재가 정상이다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_SURFACE_MERGE_ABSENT=1 \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 500 --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].name')" = "myapp-prod" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].present')" = "false" ]
  # health/sync를 종결 근거로 쓰지 않았다: 부재 조회(--ignore-not-found) 형태로만 물었다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" kubectl -n argocd get applications.argoproj.io myapp-prod -o json --ignore-not-found)" -ge 1 ]
  # presence 스타일 조회(정확히 `-o json`으로 끝나는 8-토큰 레코드)는 하나도 없어야 한다.
  # count는 접두 일치라 --ignore-not-found 레코드를 삼킨다 — exact(전체 argv 일치)로 부재를 단언한다.
  run python3 "$LEDGER_PY" exact "$CALLS" kubectl -n argocd get applications.argoproj.io myapp-prod -o json
  [ "$status" -ne 0 ]
  # 브랜치 명명 계약 원장 단언(_teardown-app.yaml SSOT).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:teardown/teardown-app-myapp-901" --jq)" -ge 1 ]
}

@test "an Application that is still present is prune-in-progress, not success" {
  printf '%s\n' "$MERGED" > "$FIX/db-prs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    STUB_SURFACE_MERGE_ABSENT=1 STUB_APP_STILL_PRESENT=1 \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 300 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].present')" = "true" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "prune"
}

@test "a cluster query error is undecided, not a converged absence" {
  printf '%s\n' "$MERGED" > "$FIX/db-prs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    STUB_SURFACE_MERGE_ABSENT=1 STUB_KUBECTL_FAIL=1 \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 300 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].error')" != "null" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].present')" = "null" ]
  # 사유는 원인별로 정확하다 — kubectl 조회 실패를 "prune 진행 중"으로 뭉개지 않는다.
  echo "$output" | jq -r '.result.pendingReason' | grep -q "클러스터 조회"
}

@test "a merge that did NOT remove the surface is a failure, not a wait" {
  printf '%s\n' "$MERGED" > "$FIX/db-prs.json"
  # STUB_SURFACE_MERGE_ABSENT 없음 = 머지 SHA에 apps/myapp 표면이 여전히 존재.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 500 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "철거가 반영되지 않"
}

@test "no KUBECONFIG omits the live section instead of claiming the prune converged" {
  printf '%s\n' "$MERGED" > "$FIX/db-prs.json"
  run --separate-stderr env PATH="$STUB" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 500 --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.omitted | join(",")')" = "live" ]
  [ "$(echo "$output" | jq -r '.result.applications')" = "null" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" kubectl)" = "0" ]
}

@test "app teardown goldens pin default-success, human-merge pending, and pruned variants (floor 3)" {
  export OUTDIR="$BATS_TEST_TMPDIR"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 500 --json > "$OUTDIR/g-success.json" 2>/dev/null || true
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 400 --wait --json > "$OUTDIR/g-pending.json" 2>/dev/null || true
  printf '%s\n' "$MERGED" > "$FIX/db-prs.json"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_SURFACE_MERGE_ABSENT=1 \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 500 --wait --json > "$OUTDIR/g-pruned.json" 2>/dev/null || true
  n=0
  for g in success pending pruned; do
    diff -u "tools/tests/fixtures/homelab/app-teardown-$g.golden.json" "$OUTDIR/g-$g.json"
    n=$((n+1))
  done
  [ "$n" -eq 3 ]
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const g of ["success", "pending", "pruned"]) {
      const env = JSON.parse(readFileSync("tools/tests/fixtures/homelab/app-teardown-" + g + ".golden.json", "utf8"));
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(g + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:3$"
}

@test "teardown is the only destructive verb in the catalog (MCP exposure premise, floor 1)" {
  # 티켓 12(MCP)가 이 표시로 파괴 동사를 걸러낸다 — 여기서 전제를 원장으로 고정한다.
  # 바닥값(=1)이 있어 "표시가 아무 데도 없음"이 vacuous green이 되지 않는다.
  run bun -e '
    import { VERBS } from "./tools/lib/verbs.ts";
    const marked = VERBS.filter((v) => v.destructive === true).map((v) => v.path.join(" "));
    if (marked.length !== 1 || marked[0] !== "app teardown") {
      console.error("파괴 표시 집합 불일치: " + JSON.stringify(marked)); process.exit(1);
    }
    console.log("destructive:" + marked.length);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^destructive:1$"
}

@test "app teardown rejects a bad app name as a usage error and prints usage on --help" {
  run --separate-stderr env PATH="$STUB" "$BUN" tools/homelab.ts app teardown "Bad_Name" --confirm "Bad_Name" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run bun tools/homelab.ts app teardown --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--confirm"
  echo "$output" | grep -q "부재"
}
