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
  # 목록을 in_progress로 둬 conclusion 폴링(step 3)이 실제로 돌게 한다 — 목록이 이미 completed/failure면
  # 아래 db-run.json 픽스처가 한 번도 읽히지 않아 이 이름이 약속한 경로가 사문이었다(티켓 19).
  printf '[{"id":501,"name":"✨ create-database — mydb [%s]","status":"in_progress","conclusion":null,"html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}]\n' "$NONCE" > "$FIX/db-runs.json"
  printf '{"status":"completed","conclusion":"failure","html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}\n' > "$FIX/db-run.json"
  printf '["validate"]\n' > "$FIX/db-run-jobs.json"
  run_db_create --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.run.failedJobs | join(",")')" = "validate" ]
  echo "$output" | jq -r '.result.run.url' | grep -q "runs/501"
  # 전이가 폴링으로 관측됐다는 증인(픽스처가 사문이 아니다).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/actions/runs/501" --jq "{status, conclusion, html_url}")" -ge 1 ]
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
  # 문구가 아니라 **좌표**가 진단 재료다 — 어느 브랜치를 봤는지가 에러에 실린다(티켓 19).
  echo "$output" | jq -r '.result.error' | grep -q "create-database/mydb-501"
  # 재시도는 유한하다 — 정확히 1 + PR_GRACE_RETRIES(3)회. 상수가 바뀌면 여기서 red(의도된 핀).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" = "4" ]
}

# ── conclusion 폴링·PR 특정 분기의 증인(homelab-cli-r2 티켓 19) ─────────────────────────────
# 라이브의 **기본 경로**는 dispatch → queued → in_progress → completed다. 그 전이를 밟는 픽스처가
# 0건이라 step 3(conclusion 폴링)의 병합·실패 판정·'진행 중' pending이 전부 무증인이었다.
# PR 특정의 판정 분기(0건·≥2 race·조회 실패)도 같은 이유로 픽스처가 없었다.

@test "a queued run transitions through the conclusion poll to completed/success" {
  printf '[{"id":501,"name":"✨ create-database — mydb [%s]","status":"queued","conclusion":null,"html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}]\n' "$NONCE" > "$FIX/db-runs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_RUN_COMPLETE_AFTER_FIRST=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 2000 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.run.id')" = "501" ]
  [ "$(echo "$output" | jq -r '.result.run.conclusion')" = "success" ]
  # 폴링이 실제로 돌았다 — 첫 조회 in_progress, 둘째 조회 completed로 최소 2회.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/actions/runs/501" --jq "{status, conclusion, html_url}")" -ge 2 ]
}

@test "a run that stays in_progress to the deadline is a pending with the in-progress reason" {
  printf '[{"id":501,"name":"✨ create-database — mydb [%s]","status":"in_progress","conclusion":null,"html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}]\n' "$NONCE" > "$FIX/db-runs.json"
  printf '{"status":"in_progress","conclusion":null,"html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}\n' > "$FIX/db-run.json"
  run_db_create --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "진행 중"
  # 재개 경로는 핸들이다 — pending에 run URL이 실린다.
  echo "$output" | jq -r '.result.run.url' | grep -q "runs/501"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/actions/runs/501" --jq "{status, conclusion, html_url}")" -ge 1 ]
}

@test "a completed run with a null conclusion fails immediately (current behavior pinned as intent)" {
  # ⚠️ 현행 동작을 **의도로** 핀한다: completed인데 conclusion이 null이면 run 실패로 읽고 즉결한다.
  # 낡은 스냅샷(status는 completed로 반영됐는데 conclusion이 아직 안 채워진 응답)에서는 거짓 실패가
  # 될 수 있다 — 재개 조건: **라이브 관측**(그 응답을 실제로 본 run 하나). 그 증거가 나오기 전에는
  # 폴링 대상으로 바꾸지 않는다(바꾸면 진짜 무결론 run이 데드라인까지 대기로 접힌다).
  printf '[{"id":501,"name":"✨ create-database — mydb [%s]","status":"completed","conclusion":null,"html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}]\n' "$NONCE" > "$FIX/db-runs.json"
  printf '["validate"]\n' > "$FIX/db-run-jobs.json"
  run_db_create --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "run 실패"
  # 즉결의 증인 — conclusion 폴링에 들어가지 않는다(단건 run 조회 0회).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/actions/runs/501" --jq "{status, conclusion, html_url}")" = "0" ]
  # 양성 대조(같은 @test 안) — 같은 조회 경로가 in_progress 픽스처에서는 실제로 불린다.
  : > "$CALLS"
  printf '[{"id":501,"name":"✨ create-database — mydb [%s]","status":"in_progress","conclusion":null,"html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}]\n' "$NONCE" > "$FIX/db-runs.json"
  printf '{"status":"in_progress","conclusion":null,"html_url":"https://github.com/ukyi-app/homelab/actions/runs/501"}\n' > "$FIX/db-run.json"
  run_db_create --json
  [ "$status" -eq 1 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/actions/runs/501" --jq "{status, conclusion, html_url}")" -ge 1 ]
}

@test "a PR listing that keeps failing is a GitHub-layer failure, not a naming drift" {
  # 0건(드리프트)과 전송 오류(미확정)는 손해 방향이 다르다 — 후자를 드리프트로 읽으면 운영자가
  # reusable 워크플로의 브랜치 명명을 뒤지게 된다. 노브 이름도 status 전용과 분리한다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_GH_PR_LOOKUP_FAIL=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "PR 조회 실패"
  # grace 재시도는 유한하다 — 정확히 1 + PR_GRACE_RETRIES(3)회 뒤에 판정한다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" = "4" ]
}

@test "two PRs on the run-id branch is a race with exit 3 and the branch coordinate" {
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null},{"number":22,"html_url":"https://github.com/ukyi-app/homelab/pull/22","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/db-prs.json"
  run_db_create --json
  [ "$status" -eq 3 ]
  [ "$(echo "$output" | jq -r '.variant')" = "race" ]
  [ "$(echo "$output" | jq -r '.result.observedRuns')" = "2" ]
  [ "$(echo "$output" | jq -r '.result.run.id')" = "501" ]
  echo "$output" | jq -r '.result.error' | grep -q "create-database/mydb-501"
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

# ── 티켓 07: 대기 구간의 진행 표시(핸들 조기 방출) ────────────────────────────────────
# 엔진은 이벤트만 낸다(MutationOpts.onProgress) — 문구·싱크는 CLI 셸 소유이고 MCP는 미주입이다.
# 계약(x-contract.stdout)의 "사람용 텍스트·진행 표시는 전부 stderr"가 여기서 실행형이 된다.

@test "progress lines put the correlation and the run URL on stderr BEFORE the envelope lands" {
  # 순서 단언 — 두 스트림을 한 파일로 합쳐 **쓰기 순서**를 잰다(파일 대상 write는 동기라 순서 보존).
  # 뒤에 나오면 아무것도 고치지 않은 것이다: 그 시점엔 봉투가 이미 같은 핸들을 담고 있다.
  # ⚠️ 사람용 보고(op 반환 **뒤**)도 correlation·run URL을 담으므로, 단순 문자열 검색으로 순서를
  #    재면 고치기 전에도 초록이다 — 진행 줄 자체(^진행: )를 앵커로 잡아야 '조기 방출'이 관측된다.
  OUT="$BATS_TEST_TMPDIR/merged.txt"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --json > "$OUT" 2>&1
  corr="$(grep -n "^진행: 디스패치 접수 — correlation ${NONCE}\$" "$OUT" | head -1 | cut -d: -f1)"
  runline="$(grep -n "^진행: run 식별 — https://github.com/ukyi-app/homelab/actions/runs/501\$" "$OUT" | head -1 | cut -d: -f1)"
  report="$(grep -n "^run: https://github.com/ukyi-app/homelab/actions/runs/501" "$OUT" | head -1 | cut -d: -f1)"
  envline="$(grep -n '"schema": "homelab-cli/1"' "$OUT" | head -1 | cut -d: -f1)"
  [ -n "$corr" ]
  [ -n "$runline" ]
  [ -n "$report" ]
  [ -n "$envline" ]
  [ "$corr" -lt "$runline" ]
  # op 반환 뒤에 나오는 두 출력(사람용 보고·봉투)보다 앞선다 = 대기 중에 이미 방출됐다.
  [ "$runline" -lt "$report" ]
  [ "$runline" -lt "$envline" ]
}

@test "with --json the progress lines go to stderr only and stdout stays exactly one envelope" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
  # 부정 단언(stdout 0건) + 같은 @test 안 양성 대조(stderr에는 실재).
  [ "$(printf '%s\n' "$output" | grep -c '^진행: ')" = "0" ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^진행: ')" -ge 3 ]
  printf '%s\n' "$stderr" | grep -q "^진행: 디스패치 접수 — correlation ${NONCE}\$"
  printf '%s\n' "$stderr" | grep -q "^진행: run 식별 — https://github.com/ukyi-app/homelab/actions/runs/501\$"
  printf '%s\n' "$stderr" | grep -q "^진행: PR 특정 — https://github.com/ukyi-app/homelab/pull/21\$"
}

@test "wait: a pending envelope already had the run and PR handles on stderr before the deadline" {
  # pending 골든과 같은 경로(--deadline-ms 400 --wait)를 --separate-stderr로 한 벌 더 돌린다:
  # 봉투가 pending인데도 핸들은 이미 방출돼 있다(중단·킬에도 재조회 좌표가 남는다).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 400 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  printf '%s\n' "$stderr" | grep -q "^진행: run 식별 — https://github.com/ukyi-app/homelab/actions/runs/501\$"
  printf '%s\n' "$stderr" | grep -q "^진행: PR 특정 — https://github.com/ukyi-app/homelab/pull/21\$"
}

@test "wait: the merge observation emits the merge SHA as its own progress line" {
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --wait --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$stderr" | grep -q "^진행: 머지 관측 — merge SHA feedbee\$"
  # 같은 @test 안 대조군 — 미머지 레인에서는 그 줄이 나오지 않는다(부정 단언의 양성 짝).
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/db-prs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 200 --wait --json
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^진행: 머지 관측')" = "0" ]
}

@test "in human mode the progress lines stay on stderr and never mix into the stdout report" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^진행: ')" = "0" ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^진행: ')" -ge 3 ]
  # 양성 대조 — 사람용 보고는 여전히 stdout이다(진행 줄만 갈라진 것이지 보고가 사라진 게 아니다).
  printf '%s\n' "$output" | grep -q "^결과: success\$"
}

# ── 티켓 08: 디스패치 타임아웃은 '실패'가 아니라 '결과 미상' ─────────────────────────────
# 자식(gh)만 SIGTERM으로 죽었을 뿐 POST는 서버에 도달했을 수 있다. 여기서 failure를 내면
# 운영자·에이전트가 재실행하고, 새 nonce가 발급돼 race 검출조차 우회한 이중 run·PR 2개가 된다.

@test "a dispatch timeout is an unconfirmed result: the engine proceeds to run identification, never redispatches" {
  # (a) run이 실제로 생겼다면 타임아웃에도 그대로 수렴한다 — 변이 argv는 정확히 1건.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    STUB_GH_DISPATCH_HANG=1 HOMELAB_TEST_DISPATCH_TIMEOUT_MS=150 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 500 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.correlation')" = "$NONCE" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run create-database.yaml)" = "1" ]
  # (b) run이 안 보이면 pending이고, 사유가 '재실행 전 Actions에서 correlation 에코 확인'을 지목한다.
  : > "$CALLS"
  printf '[]\n' > "$FIX/db-runs.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    STUB_GH_DISPATCH_HANG=1 HOMELAB_TEST_DISPATCH_TIMEOUT_MS=150 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 200 --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  [ "$(echo "$output" | jq -r '.result.correlation')" = "$NONCE" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "타임아웃"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "Actions"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run create-database.yaml)" = "1" ]
}

@test "the missing-run pending points at a resume path that exists (no correlation lookup verb)" {
  # 티켓 09 — 종전 문구는 '같은 correlation으로 재조회 가능'이었는데 correlation을 받는 조회 동사가
  # 없다(status.ts에 correlation 참조 0건). 있지도 않은 재개 수단을 약속하면 에이전트의 자연스러운
  # 다음 수는 **재디스패치**이고, 새 nonce가 발급돼 같은 이름의 PR 두 개가 난다.
  printf '[]\n' > "$FIX/db-runs.json"
  run_db_create --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "재디스패치 금지"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "Actions"
  # 부정 단언 + 같은 @test 안 양성 대조(검출기 생존).
  [ "$(echo "$output" | jq -r '.result.pendingReason' | grep -c "correlation으로 재조회")" = "0" ]
  [ "$(printf '%s\n' "큐/크론 지연 가능, 같은 correlation으로 재조회 가능" | grep -c "correlation으로 재조회")" = "1" ]
  # owner 결정 Q2 — `status --correlation` 핸들 모드는 열지 않는다(재개 조건 미충족). 그 사실이
  # 표면에도 남아 있어야 문구가 거짓말이 아니다: CLI에 그 플래그가 없고, 실재하는 --branch는 있다.
  [ "$(grep -c -- "--correlation" tools/homelab.ts)" = "0" ]
  [ "$(grep -c -- "--branch" tools/homelab.ts)" -ge 1 ]
}

@test "a non-zero dispatch stays an immediate failure (tolerance is narrowed to errKind timeout alone)" {
  # rc 1(인증 실패·입력 거부)은 '결과 미상'이 아니다 — run 특정으로 넘어가면 안 된다(대조군).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    STUB_GH_DISPATCH_FAIL=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 200 --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "디스패치 실패"
  # run 특정 조회로 넘어가지 않았다(즉시 종결).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/actions/workflows/create-database.yaml/runs?per_page=20")" = "0" ]
}
