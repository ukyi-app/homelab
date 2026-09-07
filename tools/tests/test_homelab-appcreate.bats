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

# ── 머지 없이 닫힌 PR의 종결성 · 수동 머지 레인(homelab-cli-r2 티켓 05) ─────────────────────
# create-app에서 owner가 PR을 닫는 것은 설계된 승인 경계의 정당한 결말이다 — 그 결말이 20분
# '사람 머지 대기' pending으로 위장되면 안 된다. 종결은 단건 권위 조회로 확증한 뒤에만.

@test "wait: a PR closed without merge is terminal for the manual-merge verb too (approval as context)" {
  printf '[{"number":51,"html_url":"https://github.com/ukyi-app/homelab/pull/51","merged_at":null,"merge_commit_sha":null,"state":"closed"}]\n' > "$FIX/db-prs.json"
  printf '{"number":51,"html_url":"https://github.com/ukyi-app/homelab/pull/51","merged_at":null,"merge_commit_sha":null,"state":"closed"}\n' > "$FIX/pr-confirm.json"
  run_app_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "머지 없이 닫혔다"
  # 수동 머지 동사는 approval을 부가 문맥으로만 싣는다(관측 서술 + 무엇이 승인이었는지).
  echo "$output" | jq -r '.result.error' | grep -q "공개 승인"
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "51" ]
  # 확증은 단건 권위 조회 1회 — 데드라인까지 폴링하지 않았다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls/51" --jq)" = "1" ]
  # 종결 경로에서도 승인 경계는 그대로 — gh pr 계열 argv 0건.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh pr)" = "0" ]
}

# ── 멀티소스 리비전 해석(homelab-cli-r2 티켓 01) ────────────────────────────────────────────
# 앱 Application은 멀티소스라 `status.sync.revision`이 비고 `revisions[]`만 있다 — 기본 픽스처(cli_stub.bash
# argocd-app.json)가 그 형상이고, 위 수렴 @test 2건이 그 위에서 success다(수정 전에는 단수 필드만 읽어 pending).
# 아래는 복수형의 미확정 3상(skew·none·non-sha)이 success로 접히지 않음을 밟는 음성 증인이다.

merged_pr() {
  printf '[{"number":51,"html_url":"u51","merged_at":"2026-08-24T09:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
}

@test "multi-source: one lagging source revision (skew) is not convergence — pending, raw revisions reported" {
  merged_pr
  printf '{"status":{"sync":{"status":"Synced","revisions":["feedbee","01d0e01","feedbee"]},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-app.json"
  printf 'behind\n' > "$FIX/db-compare.txt"
  run_app_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  # 계보는 원소 전부 후손이어야 true — 한 source가 behind면 false.
  [ "$(echo "$output" | jq -r '.result.applications[0].descendant')" = "false" ]
  # 관측 원본이 그대로 실려 어느 source가 낡았는지 보인다 — 확정 revision 필드는 없다.
  [ "$(echo "$output" | jq -r '.result.applications[0].revisions | join(",")')" = "feedbee,01d0e01,feedbee" ]
  [ "$(echo "$output" | jq -r '.result.applications[0] | has("revision")')" = "false" ]
}

@test "multi-source: skewed sources that are ALL descendants still never converge (no single surface ref)" {
  merged_pr
  printf '{"status":{"sync":{"status":"Synced","revisions":["feedbee","af7e70e","feedbee"]},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-app.json"
  printf 'ahead\n' > "$FIX/db-compare.txt"
  run_app_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].descendant')" = "true" ]
  # 표면은 확정된 하나의 리비전에서만 판정한다 — skew는 표면 ref를 고를 수 없어 surfaceOk 미기록,
  # 요청값 blob(ref=머지 SHA)도 읽지 않는다.
  [ "$(echo "$output" | jq -r '.result.applications[0] | has("surfaceOk")')" = "false" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/contents/apps/myapp/deploy/prod/values.yaml?ref=feedbee" --jq .sha)" = "0" ]
}

@test "multi-source: an empty revisions array or a missing key never folds to success (fail-closed pending, compare 0)" {
  merged_pr
  printf '{"status":{"sync":{"status":"Synced","revisions":[]},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-app.json"
  run_app_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].descendant')" = "false" ]
  # 관측 0 = 행에 revision도 revisions도 없다(빈 문자열로 위장하지 않는다).
  [ "$(echo "$output" | jq -r '.result.applications[0] | has("revision") or has("revisions")')" = "false" ]
  printf '{"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-app.json"
  run_app_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  # 빈 리비전이 compare 피연산자로 새지 않는다(원장에 compare 경로 0건 — 두 호출 합산).
  [ "$(python3 "$LEDGER_PY" dump "$CALLS" | grep -c 'compare/')" = "0" ]
}

@test "multi-source: a non-SHA revision (helm chart version) is undecided and NEVER reaches gh compare" {
  merged_pr
  printf '{"status":{"sync":{"status":"Synced","revisions":["10.0.1","feedbee","feedbee"]},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-app.json"
  run_app_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].revisions | join(",")')" = "10.0.1,feedbee,feedbee" ]
  [ "$(python3 "$LEDGER_PY" dump "$CALLS" | grep -c 'compare/')" = "0" ]
  # 양성 대조(검출기 생존): 기본 멀티소스 픽스처(abc1234 ≠ 머지 SHA)는 compare를 실제로 부르고 success다.
  : > "$CALLS"
  printf '{"status":{"sync":{"status":"Synced","revisions":["abc1234","abc1234","abc1234"]},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-app.json"
  run_app_create --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].revision')" = "abc1234" ]
  [ "$(python3 "$LEDGER_PY" dump "$CALLS" | grep -c 'compare/')" -ge 1 ]
}

@test "app create rejects a bad app name as a usage error and prints usage on --help" {
  run --separate-stderr env PATH="$STUB" "$BUN" tools/homelab.ts app create "Bad_Name" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run bun tools/homelab.ts app create --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "수동 머지"
}

@test "app create states the exposure boundary in a mode-agnostic way (true for public and internal apps, floor 2)" {
  # product-8: teardown은 DNS를 '내 소관 아님'이라 말하는데 create는 아무 말도 안 했다.
  # 무조건 상수(iac/tf-reconcile)는 **내부 앱에서 거짓**이 된다 — 내부 노출은 adguard rewrite 소관이다.
  # create 시점에는 표면이 아직 없어 route.public을 읽을 수 없으므로 모드-불가지 부인문을 싣는다.
  n=0
  for a in mypublic myinternal; do
    printf '[{"id":801,"name":"✨ create-app — %s [%s]","status":"completed","conclusion":"success","html_url":"https://github.com/ukyi-app/homelab/actions/runs/801"}]\n' "$a" "$NONCE" > "$FIX/appcreate-runs.json"
    run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
      "$BUN" tools/homelab.ts app create "$a" --poll-ms 10 --deadline-ms 500 --json
    [ "$status" -eq 0 ]
    e="$(echo "$output" | jq -r '.result.dnsExposure')"
    # 두 모드를 모두 담은 한 문구 — 공개 앱에서도 내부 앱에서도 참이다.
    case "$e" in *iac*) : ;; *) false ;; esac
    case "$e" in *adguard*) : ;; *) false ;; esac
    n=$((n+1))
  done
  [ "$n" -eq 2 ]
  # 대조군 — 리소스 레인(db create)은 이 필드를 싣지 않는다(공개 표면이 없는 동사).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result | has("dnsExposure")')" = "false" ]
}

# ── 디스패치 전 사전 판정(homelab-cli-r2 티켓 30) ──────────────────────────────────────────────

@test "a missing .app-config.yml on the app repo main is refused BEFORE dispatch, and a non-404 gh error still dispatches" {
  # `app init` 직후의 `app create`는 release 빌드(멀티아치, 수 분)가 끝나기 전이라 디스패처의 첫
  # 관문에서 죽고, 그 실패 run이 homelab-mutation 직렬화 큐와 Telegram 실패 알림을 소비한다
  # (appverbs-5). 결정적으로 판정 가능한 것 하나(.app-config.yml 부재)만 사전 거부로 승격한다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    STUB_APP_CONFIG_404=1 "$BUN" tools/homelab.ts app create myapp --poll-ms 10 --deadline-ms 500 --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.preflight')" = "app-config" ]
  [ "$(echo "$output" | jq -r '.result | has("correlation")')" = "false" ]
  echo "$output" | jq -r '.result.error' | grep -q ".app-config.yml"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
  # 사전 거부 봉투도 결과 계약을 만족한다(디스패치 전 거부는 correlation 없는 별도 형상이다).
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const errs = schemaErrors(JSON.parse(process.argv[1]), sch, sch);
    console.log(errs.length ? "INVALID:" + errs.join("|") : "valid");
  ' "$output"
  echo "$output" | grep -q "^valid$"

  # 반대 방향 증인 — **비-404 gh 오류는 판정 불가**이므로 통과하고 디스패처에 위임한다.
  # (이게 없으면 fail-closed 회귀가 무증인으로 들어온다.)
  : > "$CALLS"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    STUB_APP_CONFIG_ERR=1 "$BUN" tools/homelab.ts app create myapp --poll-ms 10 --deadline-ms 500 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run create-app.yaml)" = "1" ]

  # 양성 대조 — 기본(200) 경로도 디스패치한다(거부가 전칭이 아니다).
  : > "$CALLS"
  run_app_create --json
  [ "$status" -eq 0 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run create-app.yaml)" = "1" ]
  # 성공 경로 결과에는 preflight 필드가 없다(compact 생략 — 골든 3종 불변).
  [ "$(echo "$output" | jq -r '.result | has("preflight")')" = "false" ]
}
