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
  printf '[{"number":91,"html_url":"https://github.com/ukyi-app/homelab/pull/91","merged_at":null,"merge_commit_sha":null,"state":"open","head_sha":"c0ffee1"}]\n' > "$FIX/db-prs.json"
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
  # 비-TTY는 프롬프트를 **띄우지 않는다** — 이 부재가 TTY 불일치 거부와 이 거부를 구별하는 유일한
  # 관측이다(둘 다 exit 2 · gh 0건). 바로 위 `--confirm` grep이 같은 스트림의 양성 대조라, 이 0건이
  # "stderr를 안 본다"가 아님을 보증한다.
  [ "$(printf '%s' "$stderr" | grep -c "파괴 확인: 철거할 앱 이름")" = "0" ]
}

@test "a TTY prompt proceeds only when the re-entered name matches" {
  # 일치 → 디스패치까지 간다(같은 argv 계약). script가 stderr도 pty로 합치므로 프롬프트는 $output에 있다.
  run_teardown_tty myapp --json
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "파괴 확인: 철거할 앱 이름 'myapp'"
  run python3 "$LEDGER_PY" exact "$CALLS" gh workflow run teardown-app.yaml -R ukyi-app/homelab \
    -f "app=myapp" -f "confirm=myapp" -f "correlation=$NONCE"
  [ "$status" -eq 0 ]
  # 불일치 → 새 원장에서 gh 호출 0건. exit 2·gh 0건만 보면 pty가 깨져 stdin이 비-TTY가 된 경우와
  # 구별되지 않는다(그쪽도 같은 usage-error로 떨어진다) — 프롬프트 문구와 **입력 에코**가 이 절반이
  # 진짜 TTY 분기를 밟았음을 증언한다.
  : > "$CALLS"
  run_teardown_tty wrongname --json
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "파괴 확인: 철거할 앱 이름 'myapp'"
  echo "$output" | grep -q "입력: wrongname"
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
  # 사람용 렌더의 present 분기(티켓 13) — 부재를 sync/health가 아니라 prune 완료로 말한다.
  echo "$stderr" | grep -q "^Application myapp-prod: 부재 — prune 완료$"
  echo "$stderr" | grep -q "^DNS 회수: "
  # health/sync를 종결 근거로 쓰지 않았다: 부재 조회(--ignore-not-found) 형태로만 물었다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" kubectl -n argocd get applications.argoproj.io myapp-prod -o json --ignore-not-found)" -ge 1 ]
  # presence 스타일 조회(정확히 `-o json`으로 끝나는 8-토큰 레코드)는 하나도 없어야 한다.
  # count는 접두 일치라 --ignore-not-found 레코드를 삼킨다 — exact(전체 argv 일치)로 부재를 단언한다.
  run python3 "$LEDGER_PY" exact "$CALLS" kubectl -n argocd get applications.argoproj.io myapp-prod -o json
  [ "$status" -ne 0 ]
  # 브랜치 명명 계약 원장 단언(_teardown-app.yaml SSOT).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:teardown/teardown-app-myapp-901" --jq)" -ge 1 ]
  # 양성 대조 — 이 초록이 **두 ref 관측**으로 서 있다: 머지 SHA 부재 + 철거 전 ref(first parent) 실재.
  # 아래 두 argv가 없으면 성공은 표면 축 없이 난 것이다(다음 테스트가 그 공백의 손해를 잰다).
  run python3 "$LEDGER_PY" exact "$CALLS" gh api "repos/ukyi-app/homelab/commits/feedbee" --jq ".parents[0].sha"
  [ "$status" -eq 0 ]
  run python3 "$LEDGER_PY" exact "$CALLS" gh api "repos/ukyi-app/homelab/contents/apps/myapp/deploy/prod/values.yaml?ref=dadfeed" --jq .sha
  [ "$status" -eq 0 ]
}

@test "a surface absent at the pre-teardown ref too is a failure, never a silent teardown approval" {
  printf '%s\n' "$MERGED" > "$FIX/db-prs.json"
  # STUB_SURFACE_NEVER=1 = 어느 ref에서도 404. 라이브에서 이 모양을 내는 사유는 여럿이다 —
  # surfacePath 오타·표면 드리프트·이미 부재. 종전에는 셋 다 "철거 완료"와 같은 값(success)이었고,
  # 손해 방향이 파괴 승인이었다. 부재가 관측이 되려면 철거 전 ref에 실재했어야 한다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    STUB_SURFACE_NEVER=1 \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 300 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "철거 전 ref(dadfeed)"
  echo "$output" | jq -r '.result.error' | grep -q "부재가 철거의 증거가 아니다"
  # 판정이 표면 축에서 끝났다 — 클러스터 부재 조회를 근거로 삼지 않았다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" kubectl)" = "0" ]
}

@test "an undecided pre-teardown ref is pending, not a converged absence" {
  printf '%s\n' "$MERGED" > "$FIX/db-prs.json"
  # (1) first parent 조회 자체가 전송 오류 — 철거 전 ref를 특정하지 못한 미확정.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    STUB_SURFACE_MERGE_ABSENT=1 STUB_PARENT_FAIL=1 \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 300 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "철거 전 ref"
  # (2) 철거 전 ref는 특정됐으나 그 ref의 blob 조회가 전송 오류 — 같은 미확정 극성.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    STUB_SURFACE_MERGE_ABSENT=1 STUB_SURFACE_BEFORE_ERROR=1 \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 300 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "철거 전 ref"
  # (3) parents가 비어 있는 root 커밋도 성공이 아니라 미확정이다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    STUB_SURFACE_MERGE_ABSENT=1 STUB_PARENT_ROOT=1 \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 300 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
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

@test "app teardown goldens pin default-success, human-merge pending, pruned, failure, and race variants (floor 5)" {
  # 티켓 25 (d): teardownFailure·teardownRace는 mutation*과 별개 수제 정의라 드리프트 위험이 공유
  # 정의보다 큰데 골든이 없었다(합성 표본만이 증인). 두 셀을 엔진 산출로 승격한다.
  export OUTDIR="$BATS_TEST_TMPDIR"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 500 --json > "$OUTDIR/g-success.json" 2>/dev/null || true
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 400 --wait --json > "$OUTDIR/g-pending.json" 2>/dev/null || true
  # race — 같은 nonce를 에코하는 run이 2개(신원 판정 불가, exit 3).
  printf '[{"id":901,"name":"x [%s]","status":"completed","conclusion":"success","html_url":"u1"},{"id":902,"name":"y [%s]","status":"completed","conclusion":"success","html_url":"u2"}]\n' "$NONCE" "$NONCE" > "$FIX/teardown-runs.json"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 500 --json > "$OUTDIR/g-race.json" 2>/dev/null || true
  printf '[{"id":901,"name":"🗑️ teardown-app — myapp [%s]","status":"completed","conclusion":"success","html_url":"https://github.com/ukyi-app/homelab/actions/runs/901"}]\n' "$NONCE" > "$FIX/teardown-runs.json"
  printf '%s\n' "$MERGED" > "$FIX/db-prs.json"
  # failure — 머지됐는데 머지 SHA에 표면이 남아 있다(철거 미반영, 극성 반전).
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 500 --wait --json > "$OUTDIR/g-failure.json" 2>/dev/null || true
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_SURFACE_MERGE_ABSENT=1 \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 500 --wait --json > "$OUTDIR/g-pruned.json" 2>/dev/null || true
  n=0
  for g in success pending pruned failure race; do
    diff -u "tools/tests/fixtures/homelab/app-teardown-$g.golden.json" "$OUTDIR/g-$g.json"
    n=$((n+1))
  done
  [ "$n" -eq 5 ]
  # variant 다양성 — 다섯 골든이 서로 다른 셀을 덮는지(같은 variant 다섯 벌이면 floor가 무의미).
  [ "$(jq -r '.variant' "$OUTDIR"/g-*.json | LC_ALL=C sort -u | wc -l | tr -d ' ')" = "4" ]
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const g of ["success", "pending", "pruned", "failure", "race"]) {
      const env = JSON.parse(readFileSync("tools/tests/fixtures/homelab/app-teardown-" + g + ".golden.json", "utf8"));
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(g + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:5$"
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

@test "every teardown variant states that db/cache resources are retained, not reclaimed (floor 4)" {
  # product-3: teardown-app의 계약은 'DB/캐시 conn·CR·Valkey는 절대 비접촉'인데 결과는 DNS만
  # '내 소관 아님'이라 말하고 잔여는 침묵했다(지금 레포가 그 잔여 3건을 안고 있다).
  # dnsReclaim과 **같은 형식**으로 4 variant 전부에 싣는다 — 반쯤 착지한 순간이 가장 헷갈린다.
  # 후보 열거는 하지 않는다(이름≠앱 케이스). 문구는 소관 이관이 아니라 **미완 작업**을 드러낸다.
  n=0
  for g in success pending pruned failure race; do
    [ "$(jq -r '.result.resourcesRetained' "tools/tests/fixtures/homelab/app-teardown-$g.golden.json")" = "teardown-resource" ]
    n=$((n+1))
  done
  [ "$n" -eq 5 ]
  # 4 variant 전부가 실제로 덮였는지 — 골든 다섯이 success/pending/failure/race를 낸다.
  [ "$(jq -r '.variant' tools/tests/fixtures/homelab/app-teardown-*.golden.json | LC_ALL=C sort -u | tr '\n' ',')" = "failure,pending,race,success," ]
  # 스키마가 required로 강제한다 — 필드를 지운 envelope은 red다(부정 단언 + 양성 대조).
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const g of ["success", "pending", "pruned", "failure", "race"]) {
      const env = JSON.parse(readFileSync("tools/tests/fixtures/homelab/app-teardown-" + g + ".golden.json", "utf8"));
      if (schemaErrors(env, sch, sch).length) { console.error(g + ": 원본이 이미 무효"); process.exit(1); }
      delete env.result.resourcesRetained;
      if (schemaErrors(env, sch, sch).length === 0) { console.error(g + ": resourcesRetained 없이도 통과"); process.exit(1); }
      n++;
    }
    console.log("required:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^required:5$"
  # 사람용 렌더도 같은 사실을 말한다 — 미완 작업임이 드러나야 한다(소관 이관 문구 금지).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts app teardown myapp --confirm myapp --poll-ms 10 --deadline-ms 500
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "teardown-resource"
}

@test "a bad wait flag is a usage error BEFORE the TTY destruction prompt (notation and range axes)" {
  # 종전 순서는 APP_NAME_RE → confirm 프롬프트 → appTeardownInputError였다: 사람이 파괴 확인을
  # 타이핑한 뒤에야 usage 오류를 봤다(appverbs-12). 표기 축(--poll-ms abc)은 파서의 십진 술어가
  # 이미 앞에서 잡지만 **범위 축**(0)은 그 뒤였다 — 두 축을 한 자리에서 잰다.
  n=0
  for badflag in "--poll-ms abc" "--poll-ms 0" "--deadline-ms 0"; do
    : > "$CALLS"
    run bash -c "printf '%s\n' 'myapp' | script -qec \"env PATH='$STUB' KUBECONFIG='$KC' HOMELAB_CORRELATION='$NONCE' '$BUN' tools/homelab.ts app teardown myapp $badflag --json\" /dev/null"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | grep -c '파괴 확인:')" = "0" ]
    [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
    n=$((n + 1))
  done
  [ "$n" -eq 3 ]   # 열거 바닥값 — 목록이 비면 위 단언이 0회 실행돼 공허해진다
  # 양성 대조 — 같은 pty 경로에서 정상 플래그는 프롬프트를 실제로 띄운다(0건이 '못 보는 것'이 아니다).
  : > "$CALLS"
  run_teardown_tty myapp --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c '파괴 확인:')" -ge 1 ]
}
