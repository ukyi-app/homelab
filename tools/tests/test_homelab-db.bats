#!/usr/bin/env bats
# homelab db create — 공유 변이 엔진의 프로세스 경계 계약.
# 엔진 골격(스펙 대기 매트릭스): correlation nonce → 디스패치(gh workflow run) → nonce 에코
# run-name으로 자기 run 특정(정확히 1개, ≥2=race exit 3, 0=재조회 후 pending) → conclusion 추적
# (실패 시 실패 잡+run URL) → [--wait] 머지 관측 → Application 집합(cnpg-data+data-conn-prod)
# 전체 수렴(머지 SHA 후손 + Synced + Healthy + 관측 리비전의 표면 실존 — health 단독 판정 금지,
# 후손 리비전에서 표면 부재 = superseded). KUBECONFIG 부재 = 머지까지 확인 + omitted=["live"].
# 시간 심: --poll-ms/--deadline-ms 주입, nonce는 HOMELAB_CORRELATION 주입(둘 다 테스트 심).
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

# 공통 호출 — 시간 심을 밀리초로 조인 db create. 추가 인자는 그대로 전달.
run_db_create() {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 "$@"
}

@test "db create dispatches the exact contract argv: 5 ext booleans, ext_extra, correlation (ledger exact)" {
  run_db_create --ext pg_trgm,vector,hstore --json
  [ "$status" -eq 0 ]
  # 인자 경계 보존 exact 단언 — --ext 목록이 알려진 5종 불리언 + ext_extra로 정확히 매핑된다
  run python3 "$LEDGER_PY" exact "$CALLS" gh workflow run create-database.yaml -R ukyi-app/homelab \
    -f "name=mydb" -f "ext_pg_trgm=true" -f "ext_pgcrypto=false" -f "ext_citext=false" \
    -f "ext_vector=true" -f "ext_postgis=false" -f "ext_extra=hstore" -f "correlation=$NONCE"
  [ "$status" -eq 0 ]
}

@test "db create without --wait succeeds on run success and reports the PR handle" {
  run_db_create --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.verb')" = "db create" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.correlation')" = "$NONCE" ]
  [ "$(echo "$output" | jq -r '.result.waited')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.run.id')" = "501" ]
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "21" ]
  [ "$(echo "$output" | jq -r '.result.pr.merged')" = "false" ]
}

@test "db create adopts its own run amid staggered visibility of a foreign run (no misattribution)" {
  printf '[{"id":400,"name":"✨ create-database — otherdb","status":"completed","conclusion":"success","html_url":"u400"},{"id":501,"name":"✨ create-database — mydb [%s]","status":"completed","conclusion":"success","html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}]\n' "$NONCE" > "$FIX/db-runs.json"
  run_db_create --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.run.id')" = "501" ]
}

@test "two runs echoing the same nonce is a race: exit 3, race variant" {
  printf '[{"id":501,"name":"x [%s]","status":"completed","conclusion":"success","html_url":"u1"},{"id":502,"name":"y [%s]","status":"completed","conclusion":"success","html_url":"u2"}]\n' "$NONCE" "$NONCE" > "$FIX/db-runs.json"
  run_db_create --json
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r '.variant')" = "race" ]
  [ "$(echo "$output" | jq -r '.result.observedRuns')" = "2" ]
}

@test "no run echoing the nonce within the deadline is a pending partial result" {
  printf '[{"id":400,"name":"✨ create-database — otherdb","status":"queued","conclusion":null,"html_url":"u400"}]\n' > "$FIX/db-runs.json"
  run_db_create --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "미출현"
}

@test "a failed run reports the failed job names and the run URL with exit 1" {
  printf '[{"id":501,"name":"✨ create-database — mydb [%s]","status":"completed","conclusion":"failure","html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}]\n' "$NONCE" > "$FIX/db-runs.json"
  printf '{"status":"completed","conclusion":"failure","html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}\n' > "$FIX/db-run.json"
  printf '["validate"]\n' > "$FIX/db-run-jobs.json"
  run_db_create --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.run.failedJobs | join(",")')" = "validate" ]
  echo "$output" | jq -r '.result.run.url' | grep -q "runs/501"
}

@test "wait: merged PR plus full application-set convergence is a success with evidence" {
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  run_db_create --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.waited')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.pr.mergeSha')" = "feedbee" ]
  [ "$(echo "$output" | jq -r '.result.applications | length')" = "2" ]
  [ "$(echo "$output" | jq -r '[.result.applications[].surfaceOk] | unique | join(",")')" = "true" ]
  [ "$(echo "$output" | jq -r '.omitted | length')" = "0" ]
  # db 고유 계약값의 원장 단언 — 브랜치 명명(_create-database.yaml SSOT)·표면 경로(provision-db 산출).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" -ge 1 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/contents/platform/cnpg/prod/databases/mydb.yaml?ref=feedbee" --jq .sha)" -ge 1 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/contents/platform/data-conn/prod/db-mydb-conn.sealed.yaml?ref=feedbee" --jq .sha)" -ge 1 ]
}

@test "wait: stale-Healthy (old revision, Healthy+OutOfSync) never counts as success — pending" {
  printf '[{"number":21,"html_url":"u21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  printf '{"status":{"sync":{"status":"OutOfSync","revision":"0ldrev1"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-cnpg-data.json"
  printf '{"status":{"sync":{"status":"OutOfSync","revision":"0ldrev1"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-data-conn.json"
  printf 'behind\n' > "$FIX/db-compare.txt"
  run_db_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "미수렴"
}

@test "wait: partial convergence (cnpg-data only) never counts as success — pending" {
  printf '[{"number":21,"html_url":"u21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  printf '{"status":{"sync":{"status":"OutOfSync","revision":"0ldrev1"},"health":{"status":"Progressing"}}}\n' > "$FIX/argocd-data-conn.json"
  printf 'behind\n' > "$FIX/db-compare.txt"
  run_db_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
}

merged_pr_at_descendant() {
  # 머지 완료 PR + 관측 리비전이 머지 SHA의 후손(afterme, compare=ahead)인 공통 배치
  printf '[{"number":21,"html_url":"u21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  printf '{"status":{"sync":{"status":"Synced","revision":"afterme"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-cnpg-data.json"
  printf '{"status":{"sync":{"status":"Synced","revision":"afterme"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-data-conn.json"
  printf 'ahead\n' > "$FIX/db-compare.txt"
}

@test "wait: surface removed at a descendant revision is superseded with exit 3" {
  merged_pr_at_descendant
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_SURFACE_ABSENT=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --wait --json
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r '.variant')" = "superseded" ]
  echo "$output" | jq -r '.result.error' | grep -q "표면"
}

@test "wait: surface changed to a different blob at a descendant revision is superseded (content, not just existence)" {
  merged_pr_at_descendant
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_SURFACE_CHANGED=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --wait --json
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r '.variant')" = "superseded" ]
  echo "$output" | jq -r '.result.error' | grep -q "다른 내용"
}

@test "wait: a transient surface-probe transport error is NOT supersession evidence — pending, not exit 3" {
  merged_pr_at_descendant
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_SURFACE_ERROR=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 400 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
}

@test "wait: a transient compare failure is not cached as non-descendant — later cycles still converge" {
  merged_pr_at_descendant
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_COMPARE_FLAKY=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 2000 --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '[.result.applications[].descendant] | unique | join(",")')" = "true" ]
}

@test "wait without KUBECONFIG verifies up to the merge and omits the live section (exit 0)" {
  printf '[{"number":21,"html_url":"u21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.omitted | join(",")')" = "live" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" kubectl)" = "0" ]
}

@test "wait: an unmerged PR at the deadline is a pending partial result" {
  run_db_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "머지"
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "21" ]
}

@test "a failed dispatch is a failure with exit 1 (no run adopted)" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_GH_DISPATCH_FAIL=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
}

@test "db create rejects a bad name or extension as a usage error (shared identity SSOT)" {
  run --separate-stderr env PATH="$STUB" "$BUN" tools/homelab.ts db create app --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr env PATH="$STUB" "$BUN" tools/homelab.ts db create mydb --ext "bad ext" --json
  [ "$status" -eq 2 ]
}

@test "db create goldens pin the five contract variants and validate against the schema (floor 5)" {
  export OUTDIR="$BATS_TEST_TMPDIR"
  # success(no-wait)
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" "$BUN" tools/homelab.ts db create mydb --ext pg_trgm,vector,hstore --poll-ms 10 --deadline-ms 500 --json > "$OUTDIR/g-success.json" 2>/dev/null || true
  # race
  printf '[{"id":501,"name":"x [%s]","status":"completed","conclusion":"success","html_url":"u1"},{"id":502,"name":"y [%s]","status":"completed","conclusion":"success","html_url":"u2"}]\n' "$NONCE" "$NONCE" > "$FIX/db-runs.json"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --json > "$OUTDIR/g-race.json" 2>/dev/null || true
  # pending(--wait 미머지)
  printf '[{"id":501,"name":"✨ create-database — mydb [%s]","status":"completed","conclusion":"success","html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}]\n' "$NONCE" > "$FIX/db-runs.json"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 400 --wait --json > "$OUTDIR/g-pending.json" 2>/dev/null || true
  # superseded — 관측 리비전이 머지 SHA의 후손(afterme·ahead)인데 표면이 제거된 배치
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  printf '{"status":{"sync":{"status":"Synced","revision":"afterme"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-cnpg-data.json"
  printf '{"status":{"sync":{"status":"Synced","revision":"afterme"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-data-conn.json"
  printf 'ahead\n' > "$FIX/db-compare.txt"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_SURFACE_ABSENT=1 "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --wait --json > "$OUTDIR/g-superseded.json" 2>/dev/null || true
  # 생략(--wait + KUBECONFIG 부재)
  env -u KUBECONFIG PATH="$STUB" HOMELAB_CORRELATION="$NONCE" "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --wait --json > "$OUTDIR/g-omitted.json" 2>/dev/null || true
  n=0
  for g in success race pending superseded omitted; do
    diff -u "tools/tests/fixtures/homelab/db-create-$g.golden.json" "$OUTDIR/g-$g.json"
    n=$((n+1))
  done
  [ "$n" -eq 5 ]
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const g of ["success", "race", "pending", "superseded", "omitted"]) {
      const env = JSON.parse(readFileSync("tools/tests/fixtures/homelab/db-create-" + g + ".golden.json", "utf8"));
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(g + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:5$"
}

@test "db url is re-exposed as a passthrough with byte-identical behavior (dry-run parity)" {
  run bash -c "bun tools/homelab.ts db url --name t --host h --dry-run 2>&1"
  s1="$status"
  o1="$output"
  run bash -c "bun tools/db-url.ts --name t --host h --dry-run 2>&1"
  [ "$status" -eq "$s1" ]
  [ "$output" = "$o1" ]
}

@test "db create --help prints the verb usage and exits 0" {
  run bun tools/homelab.ts db create --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--ext"
  echo "$output" | grep -q -- "--wait"
}
