#!/usr/bin/env bats
# homelab app create — 수동 머지 변이의 프로세스 경계 계약.
# create-app은 머지가 곧 공개 승인(auto-merge:false — _create-app.yaml)이다. --wait는 승인 경계를
# 약화하지 않는다: 미머지면 "사람 머지 대기" 바운디드 pending, 대기 중 머지가 관측되면 자동 머지
# 동사와 같은 라이브 수렴(<app>-prod + values.yaml 표면)을 이어간다. 엔진은 어떤 경로로도
# auto-merge를 켜지 않는다 — 원장에 gh pr 계열 argv가 아예 없음을 단언한다.
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
  printf '[{"number":51,"html_url":"https://github.com/ukyi-app/homelab/pull/51","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/db-prs.json"
}

run_app_create() {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts app create myapp --poll-ms 10 --deadline-ms 500 "$@"
}

@test "app create dispatches the exact contract argv and reports the PR handle by default" {
  run_app_create --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verb')" = "app create" ]
  [ "$(echo "$output" | jq -r '.result.action')" = "create-app" ]
  [ "$(echo "$output" | jq -r '.result.run.id')" = "801" ]
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "51" ]
  [ "$(echo "$output" | jq -r '.result.pr.merged')" = "false" ]
  run python3 "$LEDGER_PY" exact "$CALLS" gh workflow run create-app.yaml -R ukyi-app/homelab \
    -f "app=myapp" -f "correlation=$NONCE"
  [ "$status" -eq 0 ]
}

@test "wait on an unmerged PR is a bounded human-merge pending and NO auto-merge argv exists" {
  run_app_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "사람 머지"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "공개 승인"
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "51" ]
  # 승인 경계 단언: gh pr 계열(merge --auto 포함) argv가 원장에 하나도 없다
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh pr)" = "0" ]
}

@test "a merge observed during wait hands over to the live convergence (app Application + surface)" {
  printf '[{"number":51,"html_url":"u51","merged_at":"2026-08-24T09:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  run_app_create --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.pr.mergeSha')" = "feedbee" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].name')" = "myapp-prod" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].surfaceOk')" = "true" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/contents/apps/myapp/deploy/prod/values.yaml?ref=feedbee" --jq .sha)" -ge 1 ]
  # 브랜치 명명 계약 원장 단언(_create-app.yaml SSOT) — stub 글롭은 fail-closed 게이트일 뿐,
  # branchFor 드리프트는 여기서 red(db/cache 인스턴스와 동형).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-app/myapp-801" --jq)" -ge 1 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh pr)" = "0" ]
}

@test "a merge arriving MID-wait (unmerged first poll, merged later) transitions to live convergence" {
  printf '[{"number":51,"html_url":"https://github.com/ukyi-app/homelab/pull/51","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/db-prs-unmerged.json"
  printf '[{"number":51,"html_url":"https://github.com/ukyi-app/homelab/pull/51","merged_at":"2026-08-24T09:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_PR_MERGE_AFTER_FIRST=1 \
    "$BUN" tools/homelab.ts app create myapp --poll-ms 10 --deadline-ms 2000 --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.pr.merged')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].name')" = "myapp-prod" ]
  # 미머지 → 머지 재폴링이 실제로 있었다(조회 ≥2)
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-app/myapp-801" --jq)" -ge 2 ]
}

@test "a failed run (missing GHCR image class) reports failed job names and the run URL" {
  printf '[{"id":801,"name":"✨ create-app — myapp [%s]","status":"completed","conclusion":"failure","html_url":"https://github.com/ukyi-app/homelab/actions/runs/801"}]\n' "$NONCE" > "$FIX/appcreate-runs.json"
  printf '{"status":"completed","conclusion":"failure","html_url":"https://github.com/ukyi-app/homelab/actions/runs/801"}\n' > "$FIX/db-run.json"
  printf '["create-app"]\n' > "$FIX/db-run-jobs.json"
  run_app_create --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.run.failedJobs | join(",")')" = "create-app" ]
  echo "$output" | jq -r '.result.run.url' | grep -q "runs/801"
}

@test "app create goldens pin default-success, human-merge pending, and merged-converged variants (floor 3)" {
  export OUTDIR="$BATS_TEST_TMPDIR"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" "$BUN" tools/homelab.ts app create myapp --poll-ms 10 --deadline-ms 500 --json > "$OUTDIR/g-success.json" 2>/dev/null || true
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" "$BUN" tools/homelab.ts app create myapp --poll-ms 10 --deadline-ms 400 --wait --json > "$OUTDIR/g-pending.json" 2>/dev/null || true
  printf '[{"number":51,"html_url":"u51","merged_at":"2026-08-24T09:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" "$BUN" tools/homelab.ts app create myapp --poll-ms 10 --deadline-ms 500 --wait --json > "$OUTDIR/g-merged.json" 2>/dev/null || true
  n=0
  for g in success pending merged; do
    diff -u "tools/tests/fixtures/homelab/app-create-$g.golden.json" "$OUTDIR/g-$g.json"
    n=$((n+1))
  done
  [ "$n" -eq 3 ]
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const g of ["success", "pending", "merged"]) {
      const env = JSON.parse(readFileSync("tools/tests/fixtures/homelab/app-create-" + g + ".golden.json", "utf8"));
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(g + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:3$"
}

@test "app create rejects a bad app name as a usage error and prints usage on --help" {
  run --separate-stderr env PATH="$STUB" "$BUN" tools/homelab.ts app create "Bad_Name" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run bun tools/homelab.ts app create --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "수동 머지"
}
