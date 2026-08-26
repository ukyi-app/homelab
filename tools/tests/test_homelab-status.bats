#!/usr/bin/env bats
# homelab status — 앱 목록/단일 앱/핸들 조회의 프로세스 경계 계약.
# 계층 계약(스펙): 레포(핀·바인딩) + GitHub(최근 run·열린 PR)가 기본, KUBECONFIG가 있으면
# ArgoCD sync/health를 덧붙이고 없으면 그 구간을 "생략"(envelope.omitted=["live"])으로 명시한다 —
# 생략은 성공(exit 0)이지 skip(4)이 아니다(부분 정보 제공이 계약). 하네스: helpers/cli_stub.bash
# (gh·kubectl PATH stub + NUL argv 원장 + --root 주입 앱 픽스처) — 라이브 무의존.
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
}

@test "status --json on a greenfield root reports an empty list with exit 0" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.verb')" = "status" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "list" ]
  [ "$(echo "$output" | jq -r '.result.count')" = "0" ]
  [ "$(echo "$output" | jq -r '.result.apps | length')" = "0" ]
}

@test "status list enumerates apps with pin, autoDeploy, and source repo" {
  make_app_fixture blog true
  make_app_fixture page false
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.count')" = "2" ]
  [ "$(echo "$output" | jq -r '[.result.apps[].name] | sort | join(",")')" = "blog,page" ]
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="blog") | .autoDeploy')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="page") | .autoDeploy')" = "false" ]
  echo "$output" | jq -r '.result.apps[] | select(.name=="blog") | .tag' | grep -q "^sha-1111111"
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="page") | .sourceRepo')" = "ukyi-app/page" ]
}

@test "status app mode reports pin, runs, lane-filtered open PRs, and live ArgoCD state" {
  make_app_fixture page true
  printf '[{"name":"release","status":"completed","conclusion":"success","head_sha":"c0ffee1","html_url":"https://github.com/ukyi-app/page/actions/runs/9"}]\n' > "$FIX/runs.json"
  # 레인 픽스처(브랜치 명명 SSOT 형식): 매치 4(bump 레거시 tag형·bump kind 인코딩 신형·secrets run_id형·
  # teardown/teardown-app-) + 배제 3(비접두 형제 'pages', 하이픈 형제 'page-extra' — 접두는 같아도 잔여가
  # tag형이 아님, 동명 bespoke target — kind가 다르면 이 앱의 브랜치가 아니다)
  printf '[{"number":7,"title":"bump page","head":"bump-poll/page-sha-abcdef1","html_url":"u1","auto_merge":true},{"number":8,"title":"secrets","head":"update-secrets/page-123","html_url":"u2","auto_merge":true},{"number":9,"title":"other app","head":"bump-poll/pages-sha-abcdef1","html_url":"u3","auto_merge":false},{"number":10,"title":"teardown","head":"teardown/teardown-app-page-456","html_url":"u4","auto_merge":false},{"number":11,"title":"sibling","head":"bump-poll/page-extra-sha-abcdef1","html_url":"u5","auto_merge":true},{"number":12,"title":"bump page new","head":"bump-poll/app/page-sha-abcdef1","html_url":"u6","auto_merge":true},{"number":13,"title":"bespoke twin","head":"bump-poll/bespoke/page-sha-abcdef1","html_url":"u7","auto_merge":false}]\n' > "$FIX/homelab-prs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "app" ]
  [ "$(echo "$output" | jq -r '.result.app.name')" = "page" ]
  echo "$output" | jq -r '.result.app.tag' | grep -q "^sha-1111111"
  [ "$(echo "$output" | jq -r '.result.app.autoDeploy')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.runs | length')" = "1" ]
  [ "$(echo "$output" | jq -r '.result.runs[0].conclusion')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.openPrs | length')" = "4" ]
  [ "$(echo "$output" | jq -r '[.result.openPrs[].number] | sort | join(",")')" = "7,8,10,12" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.sync')" = "Synced" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.health')" = "Healthy" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.revision')" = "abc1234" ]
  [ "$(echo "$output" | jq -r '.omitted | length')" = "0" ]
}

@test "status app mode reports the memory-ledger limit when the app has a ledger row" {
  make_app_fixture page true
  make_ledger_row page 64 128
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.app.ledgerMi')" = "128" ]
}

@test "status app mode omits ledgerMi when the app has no ledger row (absence is key absence)" {
  make_app_fixture page true
  make_ledger_row other-app 64 128
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.app | has("ledgerMi")')" = "false" ]
}

@test "status app mode fails loud when the homelab PR listing errors" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_PRS_FAIL=1 "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
}

@test "an in-repo app (no source-repo) skips the runs fetch and reports an empty runs list" {
  make_app_fixture local-app true -
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status local-app --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.runs | length')" = "0" ]
  [ "$(echo "$output" | jq -r '.result.app | has("sourceRepo")')" = "false" ]
  # 원장 증인: gh 호출은 열린 PR 목록 1회뿐(run 조회 없음)
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "1" ]
}

@test "status app mode without KUBECONFIG omits the live section explicitly and exits 0 (not skip)" {
  make_app_fixture page true
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.omitted | join(",")')" = "live" ]
  [ "$(echo "$output" | jq -r '.result | has("live")')" = "false" ]
  echo "$stderr" | grep -q "생략"
  # 생략이면 kubectl을 아예 부르지 않는다
  [ "$(python3 "$LEDGER_PY" count "$CALLS" kubectl)" = "0" ]
}

@test "status app mode with a broken cluster reports a live error but still succeeds" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_KUBECTL_FAIL=1 "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.live | has("error")')" = "true" ]
  [ "$(echo "$output" | jq -r '.omitted | length')" = "0" ]
}

@test "status for an unknown app fails with exit 1 and an error result" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status ghost --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "app" ]
  echo "$output" | jq -r '.result.error' | grep -q "ghost"
}

@test "status app mode fails loud when the GitHub layer errors (no silent empty lists)" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_RUNS_FAIL=1 "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
}

@test "run handle lookup reports status and conclusion from the run URL" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/1" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "run" ]
  [ "$(echo "$output" | jq -r '.result.run.status')" = "completed" ]
  [ "$(echo "$output" | jq -r '.result.run.conclusion')" = "success" ]
}

@test "run handle lookup normalizes a null conclusion by omitting the key (in-progress run)" {
  printf '{"name":"release","status":"in_progress","conclusion":null,"head_sha":"c0ffee1","html_url":"u"}\n' > "$FIX/run-handle.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/2" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.run.status')" = "in_progress" ]
  [ "$(echo "$output" | jq -r '.result.run | has("conclusion")')" = "false" ]
}

@test "pr handle lookup reports state, merged, and auto-merge from the PR URL" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --pr "https://github.com/ukyi-app/homelab/pull/7" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "pr" ]
  [ "$(echo "$output" | jq -r '.result.pr.state')" = "open" ]
  [ "$(echo "$output" | jq -r '.result.pr.merged')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.pr.autoMerge')" = "true" ]
}

@test "handle lookup on a missing operation fails with exit 1" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_HANDLE_404=1 "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/999" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
}

@test "a malformed handle URL is a usage error: exit 2, no envelope" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://gitlab.com/x/y/runs/1" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "사용법"
}

@test "a malformed PR handle URL is a usage error: exit 2, no envelope" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --pr "https://github.com/ukyi-app/homelab/issues/7" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "사용법"
}

@test "app argument and handle flags are mutually exclusive: exit 2" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --run "https://github.com/ukyi-app/page/actions/runs/1" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "the two handle flags are mutually exclusive with each other: exit 2" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/page/actions/runs/1" --pr "https://github.com/ukyi-app/homelab/pull/7" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "status --help prints the verb usage and exits 0" {
  run bun tools/homelab.ts status --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "status"
  echo "$output" | grep -q -- "--run"
  echo "$output" | grep -q -- "--pr"
}

@test "all four status modes emit schema-valid envelopes (floor 4)" {
  make_app_fixture page true
  export OUTDIR="$BATS_TEST_TMPDIR"
  for mode_args in "list:--root $APPS_ROOT" "app:page --root $APPS_ROOT" "run:--run https://github.com/ukyi-app/page/actions/runs/1" "pr:--pr https://github.com/ukyi-app/homelab/pull/7"; do
    args="${mode_args#*:}"
    env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status $args --json 2>/dev/null > "$BATS_TEST_TMPDIR/env-${mode_args%%:*}.json"
  done
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const dir = process.env.OUTDIR;
    let n = 0;
    for (const m of ["list", "app", "run", "pr"]) {
      const env = JSON.parse(readFileSync(dir + "/env-" + m + ".json", "utf8"));
      const errs = [
        ...schemaErrors(env, sch, sch),
        ...schemaErrors(env.result, sch.definitions.statusResult, sch),
      ];
      if (errs.length) { console.error(m + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:4$"
}

@test "status app mode gh calls are read-only (ledger-verified)" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  run python3 "$LEDGER_PY" gh-readonly "$CALLS"
  [ "$status" -eq 0 ]
}

@test "status human mode renders the app report in Korean on stdout" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "page"
  echo "$output" | grep -q "배포 핀"
  echo "$output" | grep -q "라이브"
}
