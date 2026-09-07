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

# 방출된 envelope을 결과 계약으로 대조한다(티켓 25 (a) — variant별 **실산출물**을 검증기에 태운다).
# 형상 결합이 없던 동안 status failure 4곳은 스키마 대조 없이 variant만 봤다.
assert_envelope_valid() {
  printf '%s\n' "$1" > "$BATS_TEST_TMPDIR/assert-env.json"
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const env = JSON.parse(readFileSync(process.argv[1], "utf8"));
    const errs = schemaErrors(env, sch, sch);
    console.log(errs.length ? "INVALID: " + errs.join(" | ") : "valid");
  ' "$BATS_TEST_TMPDIR/assert-env.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^valid$"
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

@test "status folds a non-boolean autoDeploy to false and reports a missing bindings file as key absence" {
  # 해석 SSOT는 descriptorAutoDeploy(app-surface 경유 — d4) 하나다: bindings가 실재하면 정확히
  # boolean true만 true고, non-boolean("yes")은 인가 의미론과 같은 false로 **표시**된다.
  # "미기록"(키 부재)은 bindings 파일 자체의 부재/파손뿐이다.
  make_app_fixture blog true
  make_app_fixture page '"yes"'
  make_app_fixture bare true
  rm "$APPS_ROOT/apps/bare/deploy/prod/.bindings.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="page") | .autoDeploy')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="bare") | has("autoDeploy")')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.apps[] | select(.name=="blog") | .autoDeploy')" = "true" ]
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
  [ "$(echo "$output" | jq -r '.result.live.argocd | has("revisions")')" = "false" ]
  [ "$(echo "$output" | jq -r '.omitted | length')" = "0" ]
}

@test "status live revision resolves multi-source revisions[] to one value, keeps the single-source form (control), and reports skew raw" {
  make_app_fixture page true
  # 기본 픽스처 = 멀티소스(revisions 3개·revision 키 부재) — 앱 Application의 실제 형상(티켓 01).
  [ "$(jq -r '.status.sync | has("revisions") and (has("revision") | not)' "$FIX/argocd-app.json")" = "true" ]
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.revision')" = "abc1234" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd | has("revisions")')" = "false" ]
  # 단일소스 대조군(db/cache 레인 형상) — 같은 리더가 단수 필드를 그대로 낸다.
  printf '{"status":{"sync":{"status":"Synced","revision":"abc1234"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-app.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.revision')" = "abc1234" ]
  # skew(소스 간 불일치)는 확정 revision 없이 관측 원본 revisions를 낸다(사람 렌더도 미확정 표기).
  printf '{"status":{"sync":{"status":"OutOfSync","revisions":["abc1234","def5678","abc1234"]},"health":{"status":"Progressing"}}}\n' > "$FIX/argocd-app.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.live.argocd | has("revision")')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.live.argocd.revisions | join(",")')" = "abc1234,def5678,abc1234" ]
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status page --root "$APPS_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "미확정"
}

@test "mutation and status engines share one ArgoCD revision reader (no literal sync.revision reads remain)" {
  # 티켓 01 수용 기준 — 두 엔진이 lib/argocd.ts 리더를 호출하고 단수 필드 직접 참조는 0건. 부정 카운트라
  # 같은 패턴이 리더 자신에서는 매치함을 양성 대조로 단언한다(검출기 생존).
  n=0
  for f in tools/lib/mutation.ts tools/lib/status.ts; do
    [ "$(grep -cF 'syncRevisionOf(' "$f")" -ge 1 ]
    [ "$(grep -cF 'sync?.revision' "$f")" = "0" ]
    n=$((n+1))
  done
  [ "$n" -eq 2 ]
  [ "$(grep -cF 'sync.revision' tools/lib/argocd.ts)" -ge 1 ]
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
  assert_envelope_valid "$output"
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
  assert_envelope_valid "$output"
}

@test "status app mode fails loud when the GitHub layer errors (no silent empty lists)" {
  make_app_fixture page true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_RUNS_FAIL=1 "$BUN" tools/homelab.ts status page --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  assert_envelope_valid "$output"
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
  [ "$(echo "$output" | jq -r '.result.mode')" = "run" ]
  assert_envelope_valid "$output"
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

@test "dot segments in a handle URL are refused before any gh call (traversal closed at the format gate)" {
  # 티켓 27 — owner/repo 캡처가 `[\w.-]+`라 `.`·`..`가 통과했고 그 캡처가 `repos/<o>/<r>/…`로 gh api
  # 경로에 조립됐다(`https://github.com/../../pull/1` → `repos/../../pulls/1`). identity.ts가
  # 'traversal 1차 게이트에 분기를 두지 않는다'를 원칙으로 두는데 핸들 축만 그 밖이었다.
  # 각 케이스마다 **원장 0건**을 함께 잰다 — exit 2만 보면 '거부는 했는데 그 전에 한 번 쏘았다'가 안 보인다.
  n=0
  for u in \
    "https://github.com/../x/actions/runs/1" \
    "https://github.com/x/../actions/runs/1" \
    "https://github.com/x/./actions/runs/1" \
    "https://github.com/-lead/x/actions/runs/1"; do
    : > "$CALLS"
    run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "$u" --json
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]   # 열거 바닥값 — 루프가 짧아지면 vacuous green이다
  # PR 축도 같은 술어를 쓴다(두 정규식이 함께 좁혀졌는지 — 한쪽만 고치면 다른 축이 열린 채 남는다).
  : > "$CALLS"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --pr "https://github.com/../../pull/1" --json
  [ "$status" -eq 2 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
  # 대조군 — 좁히기가 정당한 이름을 함께 막지 않았다. 점-접두 레포(`.github`)는 GitHub의 실재 이름이고
  # 임의 owner/repo 핸들을 받는 것이 이 모드의 계약이다(하네스 case가 레포를 글롭으로 두는 이유).
  : > "$CALLS"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/.github/actions/runs/1" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "run" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/.github/actions/runs/1" --jq "{name, status, conclusion, head_sha, html_url}")" = "1" ]
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

@test "status rejects an unknown option and a single-dash token with the verb usage on stderr (exit 2)" {
  # 티켓 12 — statusCli만 positionalThenFlags 골격을 손으로 다시 쓰고 있었고, 그 인라인 분기를 밟는
  # 테스트가 0건이었다(치환의 등가성 증인). `-h`는 이전엔 '앱 이름 형식 불량: -h'였다(shell-9).
  run --separate-stderr bun tools/homelab.ts status --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- "--bogus"
  echo "$stderr" | grep -q "사용법: homelab status"
  run --separate-stderr bun tools/homelab.ts status -h
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "알 수 없는 옵션"
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
        ...schemaErrors(env.result, sch.definitions.statusOk, sch),
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

# ── 티켓 09: run 모드의 브랜치 좌표(--branch) 정확 조회 ────────────────────────────────────
# pending 봉투는 run 핸들과 함께 **레인 브랜치**를 싣는다(추가 API 호출 0). 그 좌표를 받는 조회가
# 여기다 — 와일드카드 스캔이 아니라 `head=<owner>:<branch>` 정확 일치라서 형제 브랜치를 못 집는다.

@test "run mode with --branch reports the lane PR from an exact head query and never a sibling branch's PR" {
  # 대상(…mydb-501)과 형제(…mydb-5011)를 둘 다 픽스처로 둔다 — 형제가 실재해도 조회에 안 나온다.
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee","state":"closed"}]\n' > "$FIX/prs-head-create-database_mydb-501.json"
  printf '[{"number":99,"html_url":"https://github.com/ukyi-app/homelab/pull/99","merged_at":null,"merge_commit_sha":null,"state":"open"}]\n' > "$FIX/prs-head-create-database_mydb-5011.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-501" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "run" ]
  [ "$(echo "$output" | jq -r '.result.run.pr.url')" = "https://github.com/ukyi-app/homelab/pull/21" ]
  [ "$(echo "$output" | jq -r '.result.run.pr.number')" = "21" ]
  [ "$(echo "$output" | jq -r '.result.run.pr.merged')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.run.pr.mergeSha')" = "feedbee" ]
  # 질의의 정확성을 원장이 고정한다 — 이 문자열이 접두 스캔으로 바뀌면 형제 오귀속이 되살아난다.
  run python3 "$LEDGER_PY" exact "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq "[.[] | {number, html_url, merged_at, merge_commit_sha, state}]"
  [ "$status" -eq 0 ]
  # 형제 브랜치는 조회 자체가 없었다(부재 단언) + 같은 원장 질의의 양성 대조는 위 exact가 소유한다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-5011" --jq)" = "0" ]
}

@test "two PRs on the same lane branch is a race (exit 3), never a pick" {
  printf '[{"number":21,"html_url":"u21","merged_at":null,"merge_commit_sha":null},{"number":22,"html_url":"u22","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/prs-head-create-database_mydb-501.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-501" --json
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r '.variant')" = "race" ]
  [ "$(echo "$output" | jq -r '.result.observedPrs')" = "2" ]
  echo "$output" | jq -r '.result.error' | grep -q "create-database/mydb-501"
}

@test "run mode without --branch carries no pr key (the coordinate is what opens the lookup)" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.run | has("pr")')" = "false" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" = "0" ]
  # 같은 @test 안 양성 대조 — 좌표를 주면 같은 경로가 실제로 조회하고 키가 생긴다.
  : > "$CALLS"
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/prs-head-create-database_mydb-501.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-501" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.run | has("pr")')" = "true" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" = "1" ]
}

@test "--branch is refused standalone, on a foreign ref, and when its run id contradicts the run URL (no gh query leaks)" {
  # 임의 ref가 질의 문자열로 새면 안 된다 — 세 거부 레인 모두 gh 호출 0건이어야 한다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --branch "create-database/mydb-501" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q -- "--run"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "refs/heads/../evil" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "브랜치 형식"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-5011" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "5011"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api)" = "0" ]
  # 같은 @test 안 양성 대조 — 유효한 쌍은 같은 경로에서 gh 조회로 나아간다(부재 단언이 공허하지 않다).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status \
    --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-501" --json
  [ "$status" -eq 0 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api)" -ge 1 ]
}

@test "the run+branch and race envelopes validate against the schema (floor 2)" {
  export OUTDIR="$BATS_TEST_TMPDIR"
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/prs-head-create-database_mydb-501.json"
  env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-501" --json 2>/dev/null > "$OUTDIR/env-branch.json"
  printf '[{"number":21,"html_url":"u21","merged_at":null,"merge_commit_sha":null},{"number":22,"html_url":"u22","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/prs-head-create-database_mydb-501.json"
  env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --run "https://github.com/ukyi-app/homelab/actions/runs/501" --branch "create-database/mydb-501" --json 2>/dev/null > "$OUTDIR/env-race.json" || true
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const dir = process.env.OUTDIR;
    let n = 0;
    for (const m of ["branch", "race"]) {
      const env = JSON.parse(readFileSync(dir + "/env-" + m + ".json", "utf8"));
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(m + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:2$"
}

@test "an app with no deploy artifacts still surfaces the in-flight create-app PR from one open-PR listing" {
  # 그린필드의 정상 상태: create-app PR이 열려 있고(수동 머지 대기) 산출물은 아직 없다. 종전에는
  # 그 상태가 '앱 없음' failure 한 줄이라 MCP 에이전트가 이어갈 좌표가 0이었다(mcp-4).
  printf '[{"number":51,"title":"create-app myapp","head":"create-app/myapp-801","html_url":"https://github.com/ukyi-app/homelab/pull/51","auto_merge":false},{"number":52,"title":"other","head":"create-app/other-802","html_url":"u52","auto_merge":false}]\n' > "$FIX/homelab-prs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status myapp --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.createPrs | length')" = "1" ]
  [ "$(echo "$output" | jq -r '.result.createPrs[0].number')" = "51" ]
  # 형제 앱(other)의 PR은 집지 않는다(레인 판정은 tail 형식까지) + 조회는 한 번뿐.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=open&per_page=100" --jq)" = "1" ]
}

@test "status --json is an offline entry point: exit 0 and a count with gh removed from PATH" {
  # 티켓 33 — usage가 '요구: 없음'이라고 선언하는 경로에 회귀 앵커가 0건이었다(status 테스트는
  # 항상 gh 스텁을 깐다). gh만 지운 PATH로 그 주장을 실제로 잰다.
  make_app_fixture blog true
  NOGH="$BATS_TEST_TMPDIR/stub-nogh"; mkdir -p "$NOGH"
  for t in bun bash base64 cat git sleep kubectl; do ln -s "$STUB/$t" "$NOGH/$t"; done
  run --separate-stderr env PATH="$NOGH" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.count')" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
  # 같은 PATH에서 gh를 요구하는 경로는 실패한다(부재 단언의 양성 짝 — PATH 조작이 실제로 먹혔다).
  run --separate-stderr env PATH="$NOGH" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status blog --root "$APPS_ROOT" --json
  [ "$status" -eq 1 ]
}

@test "a malformed app name is a usage error: exit 2, no envelope (traversal gate, shared predicate)" {
  # status는 리더지만 app을 그대로 apps/<app>/deploy/prod 경로·kubectl 리소스명에 조립한다 —
  # identity.ts의 traversal 1차 게이트를 형제 술어(verbs/secrets/init)와 같은 문구로 공유한다.
  # `Bad_Name` 오타도 '앱 산출물이 없다' failure(1)가 아니라 usage(2)여야 원인 계층이 안 뭉개진다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status ../x --root "$APPS_ROOT" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "사용법"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status Bad_Name --root "$APPS_ROOT" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "사용법"
}

@test "status app mode reports the wired data-conn handles and omits the key when nothing is wired (floor 2)" {
  # product-1: conn이 봉인·커밋돼도 앱이 envFrom을 배선 안 하면 어떤 게이트도 안 잡았다(#211 실재발).
  # 배선 **자동화**는 하지 않는다(이름≠앱 케이스) — status가 배선 사실을 보고하는 것이 이 티켓의 범위다.
  make_app_fixture wired true
  printf 'envFrom:\n  - secretRef: { name: db-wired-conn }\n  - secretRef: { name: cache-sessions-ro-conn }\n  - secretRef: { name: wired-secrets }\n' \
    >> "$APPS_ROOT/apps/wired/deploy/prod/values.yaml"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status wired --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  # data-conn 컴포넌트가 내는 핸들만 추린다 — 앱 자기 봉인본(wired-secrets)은 배선이 아니다.
  [ "$(echo "$output" | jq -rc '.result.app.conns')" = '["db-wired-conn","cache-sessions-ro-conn"]' ]
  # 부정 단언의 양성 대조 — 배선이 없는 앱은 키 자체가 부재다(빈 배열이 아니라).
  make_app_fixture bare true
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status bare --root "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.app | has("conns")')" = "false" ]
  # 사람용 렌더도 같은 사실을 말한다(기계 채널만 알고 사람은 모르는 상태 금지).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts status wired --root "$APPS_ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "db-wired-conn"
}
