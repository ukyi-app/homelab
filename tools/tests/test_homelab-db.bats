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
  # 사람용 렌더(renderMutation)는 --json에서도 stderr로 나간다 — 필드명 오타가 무증인이던 자리(티켓 13).
  echo "$stderr" | grep -q "^db create mydb — correlation "
  echo "$stderr" | grep -q "^결과: success$"
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
  # 사람용 렌더의 pending 분기(티켓 13) — pendingReason이 '대기:' 줄로 실제로 실린다.
  echo "$stderr" | grep -q "^대기: "
  echo "$stderr" | grep -q "^결과: pending$"
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
  printf '{"status":{"sync":{"status":"OutOfSync","revision":"01d0e01"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-cnpg-data.json"
  printf '{"status":{"sync":{"status":"OutOfSync","revision":"01d0e01"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-data-conn.json"
  printf 'behind\n' > "$FIX/db-compare.txt"
  run_db_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "미수렴"
}

@test "wait: partial convergence (cnpg-data only) never counts as success — pending" {
  printf '[{"number":21,"html_url":"u21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  printf '{"status":{"sync":{"status":"OutOfSync","revision":"01d0e01"},"health":{"status":"Progressing"}}}\n' > "$FIX/argocd-data-conn.json"
  printf 'behind\n' > "$FIX/db-compare.txt"
  run_db_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
}

merged_pr_at_descendant() {
  # 머지 완료 PR + 관측 리비전이 머지 SHA의 후손(af7e70e, compare=ahead)인 공통 배치
  printf '[{"number":21,"html_url":"u21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  printf '{"status":{"sync":{"status":"Synced","revision":"af7e70e"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-cnpg-data.json"
  printf '{"status":{"sync":{"status":"Synced","revision":"af7e70e"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-data-conn.json"
  printf 'ahead\n' > "$FIX/db-compare.txt"
}

@test "wait: surface removed at a descendant revision is superseded with exit 3" {
  merged_pr_at_descendant
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_SURFACE_ABSENT=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --wait --json
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r '.variant')" = "superseded" ]
  echo "$output" | jq -r '.result.error' | grep -q "표면"
  # 사람용 렌더의 superseded 분기(티켓 13) — 오류 줄 + Application 관측 줄이 함께 실린다.
  echo "$stderr" | grep -q "^오류: "
  echo "$stderr" | grep -q "^결과: superseded$"
  echo "$stderr" | grep -q "^Application cnpg-data: sync "
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
  # superseded — 관측 리비전이 머지 SHA의 후손(af7e70e·ahead)인데 표면이 제거된 배치
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  printf '{"status":{"sync":{"status":"Synced","revision":"af7e70e"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-cnpg-data.json"
  printf '{"status":{"sync":{"status":"Synced","revision":"af7e70e"},"health":{"status":"Healthy"}}}\n' > "$FIX/argocd-data-conn.json"
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

@test "db url is a catalog op: --json yields a schema-valid envelope with no plaintext value" {
  # 구 byte-parity(패스스루가 패스스루임을 검증)는 catalog 승격으로 계약이 대체됐다(티켓 08):
  # url 동사도 op envelope 계약이고, 사람용 출력은 렌더러 소유다. usage의 --json 공통 광고가
  # 이제 10/10 동사에서 참이 된다.
  export OUTDIR="$BATS_TEST_TMPDIR"
  run --separate-stderr bun tools/homelab.ts db url --name t --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verb')" = "db url" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.dryRun')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.wrote')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "readonly" ]
  [ "$(printf '%s' "$output" | grep -c "postgres://")" = "0" ]
  echo "$output" > "$OUTDIR/url.json"
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const env = JSON.parse(readFileSync(process.env.OUTDIR + "/url.json", "utf8"));
    const errs = schemaErrors(env, sch, sch);
    if (errs.length) { console.error(errs.join(" | ")); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "db url without KUBECONFIG is a skip: exit 4, stderr marker, schema-valid skip envelope" {
  # skip 의미론(계약 exitRationale): 클러스터 도메인 부재는 '평가했고 실패(1)'가 아니라
  # '평가하지 않음(4)'이다 — 가드 어휘의 skip이 CLI variant로 같은 규약으로 흐른다(kernel-followups 06).
  export OUTDIR="$BATS_TEST_TMPDIR"
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" TS_DB_HOST=h "$BUN" tools/homelab.ts db url --name t --env-local "$BATS_TEST_TMPDIR/skip.env.local" --json
  [ "$status" -eq 4 ]
  echo "$stderr" | grep -q "^SKIP: homelab db url: "
  [ ! -f "$BATS_TEST_TMPDIR/skip.env.local" ]   # skip = 정말로 안 썼다(이 variant의 존재 이유)
  [ "$(echo "$output" | jq -r '.variant')" = "skip" ]
  [ "$(echo "$output" | jq -r '.exitCode')" = "4" ]
  [ "$(echo "$output" | jq -r '.result.wrote')" = "false" ]
  echo "$output" > "$OUTDIR/url-skip.json"
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const env = JSON.parse(readFileSync(process.env.OUTDIR + "/url-skip.json", "utf8"));
    const errs = schemaErrors(env, sch, sch);
    if (errs.length) { console.error(errs.join(" | ")); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "db url with KUBECONFIG set but a failing query is a failure, not a skip (boundary)" {
  # 경계: KUBECONFIG가 설정돼 있으면 도메인은 있다 — 조회 실패는 평가 실패(1)지 skip(4)이 아니다
  # (doctor 선례: 미설정=warn·깨진 설정=fail 의 같은 선).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" TS_DB_HOST=h STUB_KUBECTL_FAIL=1 "$BUN" tools/homelab.ts db url --name t --env-local "$BATS_TEST_TMPDIR/fail.env.local" --json
  [ "$status" -eq 1 ]
  [ ! -f "$BATS_TEST_TMPDIR/fail.env.local" ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  out="$stderr"
  run grep -q "^SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "db url enforces rw/admin exclusivity and the F2 admin channel as usage errors (engine predicate)" {
  run --separate-stderr bun tools/homelab.ts db url --name t --rw --admin
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "상호배타"
  run --separate-stderr bun tools/homelab.ts db url --name t --admin --env-local .env.local
  [ "$status" -eq 2 ]
  echo "$stderr" | grep -q "F2 채널 분리"
}

# ── PR 특정의 3상 재조회(homelab-cli-r2 티켓 04) ──────────────────────────────────────────────
# run 성공 직후 PR 목록을 단 한 번 조회해 즉결하면 낡은/빈 스냅샷 한 번이 '명명 드리프트 failure'
# (create 계열) 또는 거짓 no-op(update-secrets)이 된다. null(전송 오류)·0건은 미확정 → deadline과
# **독립한** 고정 소수 재시도 뒤에만 판정한다. 아래 정확 count는 그 재시도 횟수(엔진 상수)를 핀한다.

@test "a stale empty PR listing on the first read is retried, not a naming-drift failure (reads >= 2)" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_PR_EMPTY_FIRST=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "21" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" -ge 2 ]
}

@test "a transient PR listing transport error on the first read is retried, not a GitHub-layer failure" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_PR_FAIL_FIRST=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" -ge 2 ]
}

@test "PR grace retries run even after the deadline budget is exhausted (independent of endAt — not a vacuous fix)" {
  # --deadline-ms 1: run 식별(첫 조회에 존재)·conclusion(completed) 뒤 endAt은 이미 지났다. grace가 endAt에
  # 매달려 있으면 재시도 0회 = 첫 [] 즉결 = 오늘과 같은 failure다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_PR_EMPTY_FIRST=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 1 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" -ge 2 ]
}

@test "a persistently empty PR listing is a naming-drift failure only after the bounded retries (exact reads = 1 + 3)" {
  printf '[]\n' > "$FIX/db-prs.json"
  run_db_create --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "명명 드리프트"
  # 재시도는 유한하다 — 정확히 1 + PR_GRACE_RETRIES(3)회. 상수가 바뀌면 여기서 red(의도된 핀).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" = "4" ]
}

# ── 폴링 루프의 지속 gh 실패 사유(homelab-cli-r2 티켓 06) ───────────────────────────────────
# 세 폴링 루프(run 특정·conclusion·머지)는 관측 실패(null)를 아무 기록 없이 넘겨 데드라인에서
# '미출현/진행 중/미관측'만 냈다 — 토큰 만료·오프라인·rate limit이 전부 '큐 지연'으로 위장된다.
# 필드는 신설하지 않는다(pending 계열은 additionalProperties:false — 골든 4종이 형상을 고정):
# 사유는 pendingReason **접미**로만 실리고, 문구 SSOT는 엔진의 헬퍼 하나다.

@test "run identification: a persistent gh failure names the cause, exclusive with the absent-run reason" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_GH_RUNS_LIST_FAIL=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 1 --deadline-ms 20 --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "조회 실패"
  # stderr 첫 줄이 그대로 사유가 된다(운영자가 인증 만료를 큐 지연과 구별할 수 있어야 한다).
  echo "$output" | jq -r '.result.pendingReason' | grep -q "Bad credentials"
  # 배타성 — 진짜 미출현(빈 목록 + gh 정상)은 같은 접미를 달지 않는다. 위 레인이 양성 대조다.
  printf '[]\n' > "$FIX/db-runs.json"
  run_db_create --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  absent="$(echo "$output" | jq -r '.result.pendingReason')"
  [ "$(printf '%s' "$absent" | grep -c "미출현")" = "1" ]
  [ "$(printf '%s' "$absent" | grep -c "조회 실패")" = "0" ]
}

@test "conclusion tracking: a persistent gh failure names the cause under the in-progress reason" {
  printf '[{"id":501,"name":"✨ create-database — mydb [%s]","status":"in_progress","conclusion":null,"html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}]\n' "$NONCE" > "$FIX/db-runs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_GH_RUN_READ_FAIL=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 300 --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "진행 중"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "조회 실패"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "connection reset"
  # 핸들은 그대로 실린다 — 재개 경로는 사유가 붙어도 run URL이다.
  [ "$(echo "$output" | jq -r '.result.run.id')" = "501" ]
}

@test "merge observation: a persistent gh failure names the cause under the unmerged reason" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_GH_PR_LIST_FAIL_AFTER_FIRST=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 300 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "머지"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "조회 실패"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "rate limit exceeded"
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "21" ]
}

@test "the three polling loops share ONE failure-cause phrase (single SSOT, three call sites)" {
  # 문구를 콜사이트마다 복제하면 세 레인이 조용히 갈라진다 — 리터럴은 헬퍼 한 곳에만 있어야 한다.
  [ "$(grep -c "직전 GitHub 계층 조회 실패" tools/lib/mutation.ts)" = "1" ]
  # 양성 대조(검출기 생존): 같은 파일에서 그 헬퍼의 접미가 세 데드라인 분기에 실제로 실린다.
  [ "$(grep -c "Watch.suffix()" tools/lib/mutation.ts)" = "3" ]
}

# ── 머지 없이 닫힌 PR의 종결성(homelab-cli-r2 티켓 05) ──────────────────────────────────────
# 머지 관측 루프가 merged_at만 보면 close(미머지)가 데드라인까지 '머지 대기'로 접힌다. state를 목록
# 투영에 실어 종결 상태를 관측하되, 목록 인덱스는 단건 리소스보다 낡을 수 있으므로(함정 「GitHub
# API는 낡은 스냅샷을 200으로 돌려준다」) 단건 권위 조회로 한 번 확증한 뒤에만 failure로 종결한다.

pr_closed_unmerged() {
  # 목록이 머지 없이 닫힌 PR을 보고하는 배치(확증 픽스처 기본값도 같은 결론).
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null,"state":"closed"}]\n' > "$FIX/db-prs.json"
}

@test "the PR listing jq projection carries state (ledger argv pin — the stub never applies jq)" {
  # 스텁은 픽스처를 그대로 cat하므로 투영 누락은 픽스처만으로 무증인이다 — argv를 정적으로 고정한다.
  run_db_create --json
  [ "$status" -eq 0 ]
  run python3 "$LEDGER_PY" exact "$CALLS" gh api \
    "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" \
    --jq "[.[] | {number, html_url, merged_at, merge_commit_sha, state}]"
  [ "$status" -eq 0 ]
}

@test "wait: a PR closed without merge is a failure confirmed by exactly one authoritative read" {
  pr_closed_unmerged
  run_db_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  # 의도 추정 없는 관측 서술 — closed는 reopen 가능하므로 '거부'로 단정하지 않는다.
  echo "$output" | jq -r '.result.error' | grep -q "머지 없이 닫혔다"
  echo "$output" | jq -r '.result.error' | grep -q "state=closed, merged_at=null"
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "21" ]
  [ "$(echo "$output" | jq -r '.result.pr.merged')" = "false" ]
  # 데드라인까지 폴링하지 않았음의 증인 — pulls 조회는 목록 1 + 확증 1로 정확히 2회다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls/21" --jq)" = "1" ]
  [ "$(python3 "$LEDGER_PY" dump "$CALLS" | grep -c "/pulls")" = "2" ]
}

@test "wait: a stale closed listing overruled by the authoritative read still converges to success" {
  # 이 레인이 없으면 확증 단계 자체가 무증인이다 — 목록만 믿으면 여기서 거짓 failure가 난다.
  pr_closed_unmerged
  printf '{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee","state":"closed"}\n' > "$FIX/pr-confirm.json"
  run_db_create --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.pr.mergeSha')" = "feedbee" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls/21" --jq)" = "1" ]
}

@test "wait: a transport error on the authoritative read leaves the closed observation undecided (pending)" {
  pr_closed_unmerged
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_PR_CONFIRM_FAIL=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 200 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "머지"
  # 미확정은 종결이 아니다 — 확증 조회가 반복되며 데드라인까지 폴링했다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls/21" --jq)" -ge 2 ]
}

@test "wait: a PR row with no state key never reaches the authoritative read (strict comparison)" {
  # 기존 픽스처(state 키 부재 → undefined)는 === "closed"에 걸리지 않는다: 종전대로 데드라인 pending.
  run_db_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls/21" --jq)" = "0" ]
  # 양성 대조(같은 @test 안) — 같은 조회 경로가 state:closed 픽스처에서는 실제로 1회 불린다.
  : > "$CALLS"
  pr_closed_unmerged
  run_db_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls/21" --jq)" = "1" ]
}

@test "db url rejects a newline-carrying --host as a usage error (exit 2, no envelope, no file) — engine predicate" {
  # 티켓 03 — bin(db-url)·MCP(db_url)와 같은 술어(dbUrlInputError). 개행 host는 .env.local 행 주입 표면이다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts db url t --host $'h\nX=1' --env-local "$BATS_TEST_TMPDIR/inj.env.local" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | grep -q "host 형식"
  [ ! -e "$BATS_TEST_TMPDIR/inj.env.local" ]
}

@test "db create --help prints the verb usage and exits 0" {
  run bun tools/homelab.ts db create --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--ext"
  echo "$output" | grep -q -- "--wait"
}

@test "an engine contract breach surfaces as a labelled internal error with a stack, leaving stdout untouched (no dispatch)" {
  # shell-1 실측(티켓 13 착지 전): rc 1 · stdout 0바이트 · stderr는 Bun 소스 스니펫 + `error: …`.
  # --json 소비자는 envelope 없는 exit 1을 받았고, 그 값이 failure variant와 같아 크래시와 실패를
  # 종료코드로 구별할 수 없었다. 계약 exitCodes 집합(0/1/2/3/4)은 불변 — 판별자는 stderr 첫 줄이다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION='bad nonce!' \
    "$BUN" tools/homelab.ts db create mydb --json
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | head -1 | grep -c '^homelab db create: 내부 오류 — ')" = "1" ]
  # 스택 보존 — 도달 모집단이 계약 파손이라 스택이 유일한 증거다(HOMELAB_DEBUG 뒤로 숨기지 않는다).
  [ "$(printf '%s' "$stderr" | grep -c 'mutation\.ts')" -ge 1 ]
  # 거부는 디스패치 앞이다
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
  # 양성 대조 — 같은 하네스에서 정상 nonce는 envelope를 stdout에 낸다(단언이 전칭이 아님)
  run_db_create --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verb')" = "db create" ]
}

# ── 숫자 플래그 표기 술어(homelab-cli-r2 티켓 11) ──────────────────────────────────────────────
# 함정 원장 「TS 바닥값은 coercion 뒤에서 조용히 꺼진다」의 CLI 표면. Number()가 원문을 잃고
# (거부 문구가 NaN/0을 인용) 1e3·0x10·' 5 '·5.0을 침묵 수용했다 — 둘 다 무증인이었다.

@test "wait flags reject zero, empty and fractional values quoting the raw token, dispatching nothing (floor 4)" {
  n=0
  for i in 1 2 3 4; do
    case "$i" in
      1) flag=--poll-ms;     val=0;   want="양의 정수여야 한다: 0" ;;
      2) flag=--poll-ms;     val=abc; want="'abc'" ;;
      3) flag=--poll-ms;     val="";  want="''" ;;
      4) flag=--deadline-ms; val=1.5; want="'1.5'" ;;
    esac
    run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
      "$BUN" tools/homelab.ts db create mydb "$flag" "$val" --json
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    echo "$stderr" | grep -q "정수"
    echo "$stderr" | grep -qF "$want"
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
  # 거부는 디스패치 앞이다 — gh 원장 0건(부수효과 없음)
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
}

@test "wait flags reject the notations Number() used to accept silently and still accept plain decimals (floor 4)" {
  # bun 실측(착지 전): "1e3"→1000 · "0x10"→16 · " 5 "→5 · "5.0"→5 이 전부 ACCEPT였다.
  n=0
  for tok in "1e3" "0x10" " 5 " "5.0"; do
    run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
      "$BUN" tools/homelab.ts db create mydb --poll-ms "$tok" --json
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    echo "$stderr" | grep -qF "$tok"
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "0" ]
  # 양성 대조 — 십진 정수 표기는 그대로 통과해 디스패치까지 간다(거부가 전칭이 아님)
  run_db_create --json
  [ "$status" -eq 0 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" -ge 1 ]
}
