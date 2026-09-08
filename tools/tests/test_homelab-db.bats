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
    --jq "[.[] | {number, html_url, merged_at, merge_commit_sha, state, head_sha: .head.sha}]"
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

# ── required check(gate) 실패의 조기 종결(homelab-cli-r2 티켓 47) ────────────────────────────
# 머지 폴링이 `merged`만 보면 gate 실패가 데드라인(20분)을 통째로 태운다(2026-09-08 드릴 실측:
# gate 실패 01:06Z · CLI pending 01:15Z, 1204s · pendingReason null). 엔진은 PR head SHA의
# check-run `gate`를 함께 읽어 **가장 최신** 하나가 completed면서 통과 집합(success·neutral·skipped)
# 밖이면 failure로 조기 종결한다. 낡은 스냅샷 방어는 그 비대칭이다 — 실패 판정만 종결에 쓰고, 재실행
# (= 새 check-run)이 진행 중이면 옛 실패를 채택하지 않는다.
#
# 이 절의 판정은 **응답 순서와 무관**해야 한다(리뷰 M1): 라이브 `check-runs?filter=all`은 **최신 먼저**로
# 온다(2026-09-08 실측 — [{id 101915370989 success 02:16}, {id 101913332313 failure 02:04}]). 픽스처를
# 한 순서로만 두면 `rows[last]`처럼 순서에 기댄 구현이 초록으로 통과하므로, 재실행 레그는 **두 벌**을
# 돌려 같은 판정을 요구한다.

# 미머지 PR + head SHA(투영 SSOT는 lib/lane-pr.ts LANE_PR_FIELDS) 배치.
pr_unmerged_with_head() {
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null,"state":"open","head_sha":"c0ffee1"}]\n' > "$FIX/db-prs.json"
}

# check-run 한 줄 픽스처 — <id> <status> <conclusion|null> <started_at>. started_at은 빈 문자열·
# 비ISO도 받는다(그 형상에서 시간 비교가 조용히 왼쪽을 채택하지 않는지가 M1의 축이다).
gate_check_row() {
  printf '{"id":%s,"name":"gate","status":"%s","conclusion":%s,"html_url":"https://github.com/ukyi-app/homelab/runs/%s","started_at":"%s"}' \
    "$1" "$2" "$3" "$1" "$4"
}

# 조기 종결 레인의 공통 호출 — pending 레인이 예산을 다 태우므로 데드라인을 짧게 잡는다.
# 추가 인자는 env 대입(STUB_*)으로 넘긴다.
run_db_gate_wait() {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" "$@" \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 200 --wait --json
}

@test "wait: a failed required check ends the merge wait early as a failure carrying the check-run URL" {
  pr_unmerged_with_head
  printf '[%s]\n' "$(gate_check_row 9001 completed '"failure"' 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
  run_db_gate_wait
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "required check(gate)"
  echo "$output" | jq -r '.result.error' | grep -q "conclusion=failure"
  echo "$output" | jq -r '.result.error' | grep -q "https://github.com/ukyi-app/homelab/runs/9001"
  # 기존 핸들은 그대로 실린다 — 조기 종결이 재조회 좌표를 잃으면 안 된다.
  [ "$(echo "$output" | jq -r '.result.run.url')" = "https://github.com/ukyi-app/homelab/actions/runs/501" ]
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "21" ]
  # 조기 종결의 증인 — 머지 폴링이 예산을 태우지 않았다(PR 목록 조회는 step 4의 1회뿐).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-database/mydb-501" --jq)" = "1" ]
  # 재디스패치 0건 — 변이 argv는 최초 1회뿐이고 종결은 관측이지 재시도가 아니다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "1" ]
  # 종결 좌표는 단건 권위 조회로 확증한다(리뷰 L4) — 닫힘 종결과 같은 규약.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls/21" --jq)" -ge 1 ]
}

@test "wait: a required check still in progress keeps the existing pending path (no early exit)" {
  pr_unmerged_with_head
  printf '[%s]\n' "$(gate_check_row 9002 in_progress null 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
  run_db_gate_wait
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "머지"
  # 관측이 살아 있으므로 '관측 불가' 접미는 붙지 않는다(리뷰 L5의 음성 대조).
  [ "$(echo "$output" | jq -r '.result.pendingReason' | grep -c "관측 불가")" = "0" ]
  # 사이클마다 다시 읽는다(단발 조회가 아니다) — 대기 중 실패로 전이하면 그때 종결해야 한다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/commits/c0ffee1/check-runs?check_name=gate&filter=all&per_page=100" --jq)" -ge 2 ]
}

@test "wait: a rerun never ends the wait early, in either response order (latest-first and latest-last)" {
  # 재실행은 **새** check-run을 만든다 — 최신이 진행 중이면 옛 실패는 이번 판정의 재료가 아니다.
  # 라이브는 최신 먼저로 오고 픽스처는 최신 나중이었다(리뷰 M1) — 두 벌 다 같은 판정이어야 한다.
  old="$(gate_check_row 9003 completed '"failure"' 2026-09-08T01:00:00Z)"
  new="$(gate_check_row 9004 in_progress null 2026-09-08T01:10:00Z)"
  n=0
  for pair in "$old,$new" "$new,$old"; do
    : > "$CALLS"
    pr_unmerged_with_head
    printf '[%s]\n' "$pair" > "$FIX/gate-checks.json"
    run_db_gate_wait
    [ "$status" -eq 1 ]
    [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
    n=$((n+1))
  done
  # 양성 대조 — 같은 두-행 배치에서 **최신**이 실패로 종결하면 조기 failure다(양쪽 순서 모두).
  oldok="$(gate_check_row 9003 completed '"success"' 2026-09-08T01:00:00Z)"
  newbad="$(gate_check_row 9004 completed '"timed_out"' 2026-09-08T01:10:00Z)"
  for pair in "$oldok,$newbad" "$newbad,$oldok"; do
    : > "$CALLS"
    pr_unmerged_with_head
    printf '[%s]\n' "$pair" > "$FIX/gate-checks.json"
    run_db_gate_wait
    [ "$status" -eq 1 ]
    [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
    echo "$output" | jq -r '.result.error' | grep -q "conclusion=timed_out"
    echo "$output" | jq -r '.result.error' | grep -q "https://github.com/ukyi-app/homelab/runs/9004"
    n=$((n+1))
  done
  [ "$n" -eq 4 ]
}

@test "wait: the latest rule breaks a started_at tie by id, and a mixed started_at response is undecided" {
  # ① 동률(같은 started_at) — 재실행이 같은 초에 시작해도 **새 id**가 이긴다.
  n=0
  for pair in "$(gate_check_row 9010 completed '"failure"' 2026-09-08T01:00:00Z),$(gate_check_row 9011 in_progress null 2026-09-08T01:00:00Z)" \
              "$(gate_check_row 9011 in_progress null 2026-09-08T01:00:00Z),$(gate_check_row 9010 completed '"failure"' 2026-09-08T01:00:00Z)"; do
    : > "$CALLS"
    pr_unmerged_with_head
    printf '[%s]\n' "$pair" > "$FIX/gate-checks.json"
    run_db_gate_wait HOMELAB_TEST_GATE_BLIND_STREAK=1
    [ "$status" -eq 1 ]
    [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
    # 동률은 **관측 부재가 아니다** — 임계 1에서도 접미가 붙지 않는 것이 그 증인이다.
    [ "$(echo "$output" | jq -r '.result.pendingReason' | grep -c "관측 불가")" = "0" ]
    n=$((n+1))
  done
  # ② [리뷰 L1] started_at이 **혼합**인 응답(유효 집합도 무효 집합도 비지 않음)은 형상 이상이다.
  #    종전엔 무효 행을 조용히 버리고 유효 행만으로 최신을 잡았는데, 그 버려진 행이 사실 더 새 것이면
  #    판정이 fail-closed로 뒤집는다(모듈 규약은 「관측 부재 = fail-open」). 혼합은 접는다 — blind로 접어 pending.
  for bad in "" "not-a-timestamp"; do
    for pair in "$(gate_check_row 9012 completed '"failure"' "$bad"),$(gate_check_row 9013 in_progress null 2026-09-08T01:10:00Z)" \
                "$(gate_check_row 9013 in_progress null 2026-09-08T01:10:00Z),$(gate_check_row 9012 completed '"failure"' "$bad")"; do
      : > "$CALLS"
      pr_unmerged_with_head
      printf '[%s]\n' "$pair" > "$FIX/gate-checks.json"
      run_db_gate_wait HOMELAB_TEST_GATE_BLIND_STREAK=1
      [ "$status" -eq 1 ]
      [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
      echo "$output" | jq -r '.result.pendingReason' | grep -q "관측 불가"
      echo "$output" | jq -r '.result.pendingReason' | grep -q "started_at 혼합"
      n=$((n+1))
    done
  done
  # ③ 유효 시간이 **한 행도 없으면** 혼합이 아니다(균질 응답) — id 최대로 떨어지고 관측은 살아 있다.
  for pair in "$(gate_check_row 9014 completed '"failure"' ""),$(gate_check_row 9015 in_progress null "")" \
              "$(gate_check_row 9015 in_progress null ""),$(gate_check_row 9014 completed '"failure"' "")"; do
    : > "$CALLS"
    pr_unmerged_with_head
    printf '[%s]\n' "$pair" > "$FIX/gate-checks.json"
    run_db_gate_wait HOMELAB_TEST_GATE_BLIND_STREAK=1
    [ "$status" -eq 1 ]
    [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
    [ "$(echo "$output" | jq -r '.result.pendingReason' | grep -c "관측 불가")" = "0" ]
    n=$((n+1))
  done
  # ③ 양성 대조 — 같은 균질-무효 배치에서 **큰 id**가 실패면 종결이다(id 폴백이 살아 있다).
  : > "$CALLS"
  pr_unmerged_with_head
  printf '[%s,%s]\n' "$(gate_check_row 9016 in_progress null "")" "$(gate_check_row 9017 completed '"failure"' "")" > "$FIX/gate-checks.json"
  run_db_gate_wait HOMELAB_TEST_GATE_BLIND_STREAK=1
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "https://github.com/ukyi-app/homelab/runs/9017"
  n=$((n+1))
  [ "$n" -eq 9 ]
}

@test "latestCheckRun is order-independent and total on the same rows (unit, direct call)" {
  # 위 레그들은 엔진을 통과해서 판정을 본다 — 이 @test는 export된 술어를 **직접** 불러 순서 독립성을
  # 원소 단위로 잰다(엔진 경로가 다른 이유로 pending이 되면 위 레그가 vacuous해질 수 있다).
  run bun -e '
    import { latestCheckRun } from "./tools/lib/mutation.ts";
    const rows = [
      { id: 1, name: "gate", status: "completed", conclusion: "failure", html_url: "u1", started_at: "2026-09-08T01:00:00Z" },
      { id: 2, name: "gate", status: "in_progress", conclusion: null, html_url: "u2", started_at: "2026-09-08T01:10:00Z" },
      { id: 3, name: "gate", status: "completed", conclusion: "success", html_url: "u3", started_at: "" },
    ];
    const perm = (a) => a.map((r) => r.id).join("");
    const seen = new Set();
    // 3! = 6 순열 전수 — 어떤 순서로 와도 최신은 id 2(유효 시간 최대)여야 한다.
    const idx = [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]];
    for (const p of idx) {
      const got = latestCheckRun(p.map((i) => rows[i]));
      if (got === undefined || got.id !== 2) { console.error("order " + perm(p.map((i) => rows[i])) + " -> " + String(got && got.id)); process.exit(1); }
      seen.add(perm(p.map((i) => rows[i])));
    }
    if (seen.size !== 6) { console.error("perm floor: " + seen.size); process.exit(1); }
    // 동률은 id 최대 · 유효 시간 전무면 id 최대 · 빈 배열은 undefined.
    const tie = latestCheckRun([{ id: 7, started_at: "2026-09-08T01:00:00Z" }, { id: 9, started_at: "2026-09-08T01:00:00Z" }]);
    if (tie.id !== 9) { console.error("tie: " + tie.id); process.exit(1); }
    const noTime = latestCheckRun([{ id: 5, started_at: "x" }, { id: 6, started_at: "" }]);
    if (noTime.id !== 6) { console.error("noTime: " + noTime.id); process.exit(1); }
    if (latestCheckRun([]) !== undefined) { console.error("empty"); process.exit(1); }
    console.log("ok:6");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:6$"
}

@test "the passing set is success/neutral/skipped and every other completed conclusion ends the wait (floor 10)" {
  # 리뷰 M2 — 종전 판은 **종결 어휘**를 열거해서(failure·cancelled·timed_out) `action_required`·`stale`이
  # required check를 막으면서도 비종결로 접혔다. 통과 집합을 반전하면 상류 어휘 추가가 fail-closed다.
  n=0
  for c in failure cancelled timed_out action_required stale; do
    : > "$CALLS"
    pr_unmerged_with_head
    printf '[%s]\n' "$(gate_check_row 9006 completed "\"$c\"" 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
    run_db_gate_wait
    [ "$status" -eq 1 ]
    [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
    echo "$output" | jq -r '.result.error' | grep -q "conclusion=$c"
    n=$((n+1))
  done
  for c in success neutral skipped; do
    : > "$CALLS"
    pr_unmerged_with_head
    printf '[%s]\n' "$(gate_check_row 9007 completed "\"$c\"" 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
    run_db_gate_wait
    [ "$status" -eq 1 ]
    [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
    n=$((n+1))
  done
  # 상류가 새 어휘를 더한 형상(가정) — 통과 집합 밖이므로 종결이다(fail-closed 방향).
  : > "$CALLS"
  pr_unmerged_with_head
  printf '[%s]\n' "$(gate_check_row 9008 completed '"some_future_conclusion"' 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
  run_db_gate_wait
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "conclusion=some_future_conclusion"
  n=$((n+1))
  # completed인데 conclusion이 null인 형상도 통과 집합 밖이다 — 결론을 읽었는데 통과의 증거가 없다.
  : > "$CALLS"
  pr_unmerged_with_head
  printf '[%s]\n' "$(gate_check_row 9009 completed null 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
  run_db_gate_wait
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  n=$((n+1))
  [ "$n" -eq 10 ]
}

@test "a non-completed status is never terminal even when the conclusion field already says failure" {
  # 리뷰 M4 — `status !== "completed"` 가드가 무증인이었다. 실물 응답에서 진행 중 run의 conclusion은
  # null이지만, 낡은/이상 스냅샷이 값을 실어 보내도 status가 답이다.
  n=0
  for st in in_progress queued; do
    : > "$CALLS"
    pr_unmerged_with_head
    printf '[%s]\n' "$(gate_check_row 9020 "$st" '"failure"' 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
    run_db_gate_wait
    [ "$status" -eq 1 ]
    [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
    n=$((n+1))
  done
  [ "$n" -eq 2 ]
}

@test "a foreign check-run name never stands in for the required check (client-side name recheck)" {
  # 리뷰 L2 — 서버측 `check_name=gate` 필터의 사본인 클라이언트 재확인이 무증인이었다. 필터 의미가
  # 접두 일치로 바뀌거나(가정) 스텁이 넓게 응답하면 동명 아닌 check가 required check 노릇을 한다.
  pr_unmerged_with_head
  printf '[%s,{"id":9999,"name":"build","status":"completed","conclusion":"failure","html_url":"https://github.com/ukyi-app/homelab/runs/9999","started_at":"2026-09-08T02:00:00Z"}]\n' \
    "$(gate_check_row 9021 in_progress null 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
  run_db_gate_wait
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  [ "$(echo "$output" | jq -r '.result | has("error")')" = "false" ]
}

@test "a response that hits the page cap is undecided (truncation fail-open), and one row under it is not" {
  # 리뷰 L3 — 종전 per_page=20은 무페이지네이션이라 절단이 조용한 오종결이었다(잘려 나간 새
  # in_progress 대신 옛 실패가 최신이 된다). 상한을 100으로 올리고, 상한에 **닿으면** 판정을 접는다.
  pr_unmerged_with_head
  # 100건(상한 도달) — 그중 최신이 실패여도 종결하지 않는다.
  jq -nc '[range(100) | {id: (9100 + .), name: "gate", status: "completed", conclusion: "failure",
           html_url: ("https://github.com/ukyi-app/homelab/runs/" + (9100 + . | tostring)),
           started_at: ("2026-09-08T01:00:0" + (. % 10 | tostring) + "Z")}]' > "$FIX/gate-checks.json"
  [ "$(jq -r 'length' "$FIX/gate-checks.json")" = "100" ]
  # 접미는 **임계 주입**으로 결정론화한다(리뷰 M1) — 기본 3은 폴링 사이클 수에 종속돼 CPU 경합에서 flake다.
  run_db_gate_wait HOMELAB_TEST_GATE_BLIND_STREAK=1
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "관측 불가"
  # 99건(상한 미달)이면 같은 배치가 종결이다 — 접는 축이 '실패 개수'가 아니라 '절단 미상'임을 가른다.
  : > "$CALLS"
  jq -c 'del(.[0])' "$FIX/gate-checks.json" > "$FIX/gate-checks.tmp.json"
  mv "$FIX/gate-checks.tmp.json" "$FIX/gate-checks.json"
  [ "$(jq -r 'length' "$FIX/gate-checks.json")" = "99" ]
  run_db_gate_wait
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "conclusion=failure"
}

@test "wait: a transport error on the required-check read leaves the wait on its pending path (fail-open)" {
  pr_unmerged_with_head
  # 같은 픽스처가 **읽히면** 조기 failure다(위 @test) — 여기서 pending인 것은 조회 실패 때문이다.
  printf '[%s]\n' "$(gate_check_row 9005 completed '"failure"' 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
  run_db_gate_wait STUB_GATE_READ_FAIL=1
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "머지"
}

@test "a dead required-check observation is named in the pending reason (read failure and empty set)" {
  # [리뷰 M1] 접미는 **연속 사이클 수**의 함수라 기본 3이면 판정이 폴링 속도에 종속된다(CPU 경합 flake).
  # 임계를 심으로 주입해 **1사이클 결정론**으로 잰다 — 아래 @test가 임계 미만/이상 양쪽을 가른다.
  # 리뷰 L5 — 이름 드리프트(REQUIRED_CHECK ≠ ci.yaml job id)나 지속 조회 실패는 조기 종결을 통째로
  # 무력화하는데 pendingReason에 흔적이 0이었다. mergeWatch 접미와 **분리된** 축이다.
  n=0
  pr_unmerged_with_head
  printf '[%s]\n' "$(gate_check_row 9030 completed '"failure"' 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
  run_db_gate_wait STUB_GATE_READ_FAIL=1 HOMELAB_TEST_GATE_BLIND_STREAK=1
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "관측 불가"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "Bad Gateway"
  n=$((n+1))
  # 공집합 = 이름 드리프트와 구별되지 않는다(서버 필터가 이름으로 좁히므로 0건은 '그 이름이 없다'다).
  : > "$CALLS"
  pr_unmerged_with_head
  printf '[]\n' > "$FIX/gate-checks.json"
  run_db_gate_wait HOMELAB_TEST_GATE_BLIND_STREAK=1
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "관측 불가"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "이름"
  n=$((n+1))
  # head SHA 좌표가 없으면 질의 자체가 없다 — 그것도 관측 불가다(그리고 check-runs argv가 0건).
  : > "$CALLS"
  printf '[{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null,"state":"open"}]\n' > "$FIX/db-prs.json"
  run_db_gate_wait HOMELAB_TEST_GATE_BLIND_STREAK=1
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "관측 불가"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/commits/c0ffee1/check-runs?check_name=gate&filter=all&per_page=100" --jq)" = "0" ]
  n=$((n+1))
  [ "$n" -eq 3 ]
}

@test "the blind suffix appears only at or above the injected streak threshold (deterministic, no cycle race)" {
  # [리뷰 M1] 종전 두 @test는 접미가 붙는지를 **기본 임계 3**으로 물었다 — 그 판정은 데드라인 안에
  # 몇 사이클이 도는지에 종속되고, 그 사이클 수는 CPU 경합의 함수라 신규 flake다. 임계를 심으로
  # 주입하면 '1사이클이면 붙는다'와 '도달 불가 임계면 안 붙는다'를 둘 다 결정론으로 잰다.
  # 프로덕션 기본(3)은 불변이다 — 심이 없을 때의 값은 상수 절이 진다.
  n=0
  pr_unmerged_with_head
  printf '[]\n' > "$FIX/gate-checks.json"
  # ① 임계 1 — 첫 사이클의 관측 부재가 곧 접미다(사이클이 몇 번 돌든 붙는다).
  #    ⚠️ 연속 **횟수**는 단언하지 않는다 — 그 수는 데드라인 안에 돈 사이클 수라 여전히 CPU 경합의
  #    함수다. 결정론인 것은 접미의 **유무**이고, 이 심이 고정하는 것도 그것이다.
  run_db_gate_wait HOMELAB_TEST_GATE_BLIND_STREAK=1
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "관측 불가"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "회 연속"
  n=$((n+1))
  # ② 데드라인 안에 도달 불가한 임계 — 같은 픽스처에서 접미가 없다(사이클 수와 무관한 음성 대조).
  : > "$CALLS"
  pr_unmerged_with_head
  run_db_gate_wait HOMELAB_TEST_GATE_BLIND_STREAK=99999
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  [ "$(echo "$output" | jq -r '.result.pendingReason' | grep -c "관측 불가")" = "0" ]
  n=$((n+1))
  # ③ 형식 불량 심은 무시하고 프로덕션 기본으로 돌아간다(빈 문자열·비정수 — 「TS 바닥값」 함정).
  #    기본 3이면 짧은 데드라인에서 접미 유무가 사이클 수에 달리므로, 여기서는 **실행이 계약대로
  #    끝나는지**만 본다(pending) — 접미 단언은 위 두 레그가 결정론으로 진다.
  for bad in "" 0 3.5 abc; do
    : > "$CALLS"
    pr_unmerged_with_head
    run_db_gate_wait HOMELAB_TEST_GATE_BLIND_STREAK="$bad"
    [ "$status" -eq 1 ]
    [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
    n=$((n+1))
  done
  [ "$n" -eq 6 ]
}

@test "the terminal head SHA is confirmed against the single-PR resource before the wait ends (L4)" {
  # 리뷰 L4 — 종결 좌표(head SHA)는 **목록 스냅샷**에서 온다. 목록은 단건 리소스보다 낡을 수 있으므로
  # (함정 「GitHub API는 낡은 스냅샷을 200으로 돌려준다」) 닫힘 종결과 같은 규약으로 단건 조회 1회로
  # 확증한 뒤에만 종결한다.
  # [리뷰 M2·L3] 그 확증의 **실패·불일치**는 종전에 어느 카운터도 세지 않아 흔적 0으로 데드라인을
  # 태웠다. 이제 gate blind 축이 계상하되 사유 문구를 가른다 — 임계 주입으로 결정론이다.
  n=0
  # ① 확증이 **다른** head SHA를 보고하면(그 사이 새 push) 이번 사이클은 미확정 — 폴링을 계속한다.
  pr_unmerged_with_head
  printf '[%s]\n' "$(gate_check_row 9040 completed '"failure"' 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
  printf '{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null,"state":"open","head_sha":"deadbee"}\n' > "$FIX/pr-confirm.json"
  run_db_gate_wait HOMELAB_TEST_GATE_BLIND_STREAK=1
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "관측 불가"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "확증 불일치(목록 c0ffee1 vs 단건 deadbee)"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "새 push"
  n=$((n+1))
  # ② 확증 조회가 전송 오류여도 종결하지 않는다(일시 실패 한 번이 종결이 되면 안 된다).
  #    사유 문구는 ①과 갈린다 — '못 읽었다'와 '읽었는데 좌표가 다르다'는 다른 처방이다.
  : > "$CALLS"
  pr_unmerged_with_head
  printf '{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null,"state":"open","head_sha":"c0ffee1"}\n' > "$FIX/pr-confirm.json"
  run_db_gate_wait STUB_PR_CONFIRM_FAIL=1 HOMELAB_TEST_GATE_BLIND_STREAK=1
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "확증 실패: "
  echo "$output" | jq -r '.result.pendingReason' | grep -q "connection reset"
  [ "$(echo "$output" | jq -r '.result.pendingReason' | grep -c "확증 불일치")" = "0" ]
  n=$((n+1))
  # ③ 같은 SHA를 보고하면 종결이다 — 확증 조회가 원장에 실제로 찍힌 것이 그 증인이다.
  : > "$CALLS"
  pr_unmerged_with_head
  run_db_gate_wait
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  run python3 "$LEDGER_PY" exact "$CALLS" gh api "repos/ukyi-app/homelab/pulls/21" \
    --jq "{number, html_url, merged_at, merge_commit_sha, state, head_sha: .head.sha}"
  [ "$status" -eq 0 ]
  n=$((n+1))
  [ "$n" -eq 3 ]
}

@test "the blind streak accumulates across cycles even when the check-run read itself succeeds" {
  # [리뷰 M2] 한 사이클은 관측이 **둘**이다 — check-run 조회와 종결 좌표 확증. 계상이 관측 단위면
  # 앞 관측(조회 성공)이 뒤 관측(확증 불일치)의 스트릭을 같은 사이클 안에서 곧바로 지워, 지속되는
  # 확증 불일치가 임계 2에 영영 못 닿는다(흔적 0으로 데드라인을 태우던 종전 형상 그대로다).
  # 사이클 단위 계상이라야 그 상태가 접미로 올라온다.
  pr_unmerged_with_head
  printf '[%s]\n' "$(gate_check_row 9060 completed '"failure"' 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
  printf '{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null,"state":"open","head_sha":"deadbee"}\n' > "$FIX/pr-confirm.json"
  # 임계 2 — 두 사이클이 **필요**하다. 데드라인은 그 사이클 예산의 10배 이상을 준다(폴링 10ms).
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    HOMELAB_TEST_GATE_BLIND_STREAK=2 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 3000 --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "관측 불가"
  echo "$output" | jq -r '.result.pendingReason' | grep -q "확증 불일치"
}

@test "an authoritative row that reports the PR merged wins over the gate verdict (stale listing, merged PR)" {
  # [리뷰 M3] 종결 직전 권위 단건 조회는 이미 merged_at·merge_commit_sha를 싣고 온다(LANE_PR_FIELDS).
  # 종전 확증은 boolean이라 그 필드를 버렸다 — 목록이 낡아 open으로 오는 사이 gate가 실패로 끝났고
  # 사람이 admin으로 머지한 형상에서, **머지된 PR을 failure로 보고**했다. 닫힘 종결과 같은 순서다:
  # 권위 행이 머지를 말하면 그 값으로 정상 머지 경로를 잇는다.
  pr_unmerged_with_head
  printf '[%s]\n' "$(gate_check_row 9050 completed '"failure"' 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
  printf '{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":"2026-09-08T01:05:00Z","merge_commit_sha":"feedbee","state":"closed","head_sha":"c0ffee1"}\n' > "$FIX/pr-confirm.json"
  run_db_create --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.pr.merged')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.pr.mergeSha')" = "feedbee" ]
  [ "$(echo "$output" | jq -r '.result | has("error")')" = "false" ]
  # 음성 대조(같은 @test 안) — 같은 gate 픽스처인데 권위 행이 미머지면 종전대로 조기 failure다.
  : > "$CALLS"
  pr_unmerged_with_head
  printf '{"number":21,"html_url":"https://github.com/ukyi-app/homelab/pull/21","merged_at":null,"merge_commit_sha":null,"state":"open","head_sha":"c0ffee1"}\n' > "$FIX/pr-confirm.json"
  run_db_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "required check(gate)"
}

@test "the required-check read carries the head SHA coordinate and the exact projection (ledger argv pin)" {
  # 스텁은 픽스처를 그대로 cat하므로 좌표·투영 누락은 픽스처만으로 무증인이다 — argv를 정적으로 고정한다.
  # head SHA가 PR 투영에서 오는 것도 여기서 고정된다(c0ffee1 = pr_unmerged_with_head의 head_sha).
  pr_unmerged_with_head
  printf '[%s]\n' "$(gate_check_row 9008 completed '"failure"' 2026-09-08T01:00:00Z)" > "$FIX/gate-checks.json"
  run_db_gate_wait
  [ "$status" -eq 1 ]
  run python3 "$LEDGER_PY" exact "$CALLS" gh api \
    "repos/ukyi-app/homelab/commits/c0ffee1/check-runs?check_name=gate&filter=all&per_page=100" \
    --jq "[.check_runs[] | {id, name, status, conclusion, html_url, started_at}]"
  [ "$status" -eq 0 ]
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
  # run 특정 조회로 넘어가지 않았다(즉시 종결) — **식별 루프의 투영**으로 잰다. 같은 endpoint에
  # 디스패치 **전** 신선도 스냅샷(티켓 27)이 하나 더 있으므로 경로 접두만 세면 그 1건과 뒤섞인다.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/actions/workflows/create-database.yaml/runs?per_page=20" --jq "[.workflow_runs[] | {id, name, status, conclusion, html_url}]")" = "0" ]
  # 그 스냅샷은 디스패치보다 앞이므로 실패 레인에서도 정확히 1회 관측된다(무-질의로 접히지 않았다).
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/actions/workflows/create-database.yaml/runs?per_page=20" --jq "[.workflow_runs[] | {id, name}]")" = "1" ]
}

@test "a completed run echoing the same nonce from BEFORE the dispatch is never adopted (freshness snapshot)" {
  # 티켓 27 — 고정 nonce(HOMELAB_CORRELATION)가 프로덕션에서 켜지면 같은 nonce의 **이전** run이 홀로
  # 매치돼 옛 conclusion·옛 PR 핸들이 이번 실행의 결과로 보고됐다(수령증 루프의 0건 분기가 그 문이다).
  # 스냅샷 픽스처가 그 옛 run(501)을 디스패치 **전에** 보여주면 채택 대상에서 빠지고, 이 하네스의
  # 목록 픽스처에는 그것뿐이라 데드라인까지 새 run이 안 나타나 pending으로 끝난다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    STUB_GH_STALE_RUN=1 \
    "$BUN" tools/homelab.ts db create mydb --poll-ms 10 --deadline-ms 60 --json
  [ "$status" -eq 1 ]   # pending=1(계약 exitCodes — '확인하지 못함'이 0이면 && 체인에 vacuous green)
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  # 옛 run의 핸들이 결과로 새지 않았다 — 부재는 키 부재로 보고된다(값 없음 = 키 없음 규약).
  [ "$(echo "$output" | jq -r '.result | has("run")')" = "false" ]
  echo "$output" | jq -r '.result.pendingReason' | grep -q "run 미출현"
  # 대조군(같은 픽스처·스냅샷만 공집합) — 신선도 배제가 없으면 그 run을 채택해 success가 된다.
  # 이 줄이 없으면 위 pending이 '스텁이 그냥 비었다'와 구별되지 않는다(vacuous).
  run_db_create --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.run.id')" = "501" ]
}

@test "a schema-violating envelope dies loud at emit time (runtime self-check mutation)" {
  # contract-7: 골든이 없는 셀은 엔진이 계약을 어겨도 아무도 모른다 — 방출 직전 자기검증이 그 침묵을
  # 닫는다. 뮤테이션은 **사본 트리의 스키마**에 가짜 required 필드를 넣어 엔진 산출을 위반으로 만든다
  # (작업 트리는 불변). node_modules는 심링크로 들여온다(사본 트리는 /tmp라 상위 해석이 없다).
  T="$BATS_TEST_TMPDIR/selfcheck"
  mkdir -p "$T/tools"
  cp -R tools/lib "$T/tools/lib"
  cp tools/homelab.ts "$T/tools/homelab.ts"
  ln -s "$ROOT/node_modules" "$T/node_modules"
  sed 's|"required": \["id", "url"\],|"required": ["id", "url", "bogusRequiredField"],|' \
    tools/cli-result-schema.json > "$T/tools/cli-result-schema.json"
  # sed 무매치의 vacuous green 차단 — 뮤테이션이 정확히 1곳(mutationRun) 적용됐는지 먼저 확인한다.
  [ "$(grep -c '"bogusRequiredField"' "$T/tools/cli-result-schema.json")" = "1" ]
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" "$T/tools/homelab.ts" db create mydb --poll-ms 10 --deadline-ms 500 --json
  [ "$status" -ne 0 ]
  echo "$stderr" | grep -q "계약 파손"
  # 양성 대조 — 같은 사본 트리에 원본 스키마를 두면 초록이다(트리 복사 실패로 red가 아님을 증명).
  cp tools/cli-result-schema.json "$T/tools/cli-result-schema.json"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" "$T/tools/homelab.ts" db create mydb --poll-ms 10 --deadline-ms 500 --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
}

# ── 티켓 18: 라이브 성공 경로의 증인 ──────────────────────────────────────────────────────────

@test "db url live success writes the rehosted URL to the target file and leaks plaintext on neither channel" {
  # connurl-7: 레포 전체에서 `wrote == true` 단언이 **0건**이었다 — 평문 비출력도 dry-run·skip·
  # failure 레인에서만 쟀다. 즉 이 동사의 **유일한 실효 경로**(자격을 실제로 기록하는 경로)가
  # 무증인이었고, `--json`에서 사람용 보고가 stderr로 가는 순간의 stderr 평문 부재는 아무도 안 쟀다.
  T="$BATS_TEST_TMPDIR/live.env.local"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" TS_DB_HOST=h "$BUN" tools/homelab.ts db url t --env-local "$T" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verb')" = "db url" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.wrote')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.dryRun')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.envFile')" = "$T" ]
  # 파일 내용 — host가 tailscale LB로 치환된 **완성 행**이다(rehost가 no-op이면 여기서 red).
  [ -s "$T" ]
  grep -q '^T_RO_DATABASE_URL=postgres://u:p@h:5432/db$' "$T"
  # 두 채널 어디에도 평문이 없다. --json이라 사람용 렌더는 stderr에 있는데, 그 렌더도 값을 안 낸다.
  [ "$(printf '%s%s' "$output" "$stderr" | grep -c 'postgres://')" = "0" ]
  # 부재 단언의 양성 짝 — 같은 문자열이 기록 파일에는 실재한다(grep 패턴이 죽은 게 아니다).
  [ "$(grep -c 'postgres://' "$T")" = "1" ]
  export OUTDIR="$BATS_TEST_TMPDIR"
  echo "$output" > "$OUTDIR/url-live.json"
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const env = JSON.parse(readFileSync(process.env.OUTDIR + "/url-live.json", "utf8"));
    const errs = schemaErrors(env, sch, sch);
    if (errs.length) { console.error(errs.join(" | ")); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok$"
}

@test "the dry-run plan reflects the mode and target wiring: default, --rw with --env-local, and --admin (floor 3)" {
  # 종전 dry-run 레인은 mode/wrote만 봤다 — `--rw`·`--env-local`·`--admin`의 배선이 유실돼도
  # 전건 침묵 통과였다(계획 보고가 계획을 보고하지 않는다). 세 레인을 같은 @test에서 대조한다.
  n=0
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" TS_DB_HOST=h "$BUN" tools/homelab.ts db url t --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "readonly" ]
  [ "$(echo "$output" | jq -r '.result.envKey')" = "T_RO_DATABASE_URL" ]
  [ "$(echo "$output" | jq -r '.result.envFile')" = ".env.local" ]
  n=$((n + 1))
  T2="$BATS_TEST_TMPDIR/rw.env.local"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" TS_DB_HOST=h "$BUN" tools/homelab.ts db url t --rw --env-local "$T2" --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "owner-readwrite" ]
  [ "$(echo "$output" | jq -r '.result.envKey')" = "T_DATABASE_URL" ]
  [ "$(echo "$output" | jq -r '.result.envFile')" = "$T2" ]
  n=$((n + 1))
  # --admin은 채널 분리(F2) — 대상 파일 오버라이드가 불가하므로 계획도 .env.admin.local 고정이다.
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" TS_DB_HOST=h "$BUN" tools/homelab.ts db url t --admin --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "admin-superuser" ]
  [ "$(echo "$output" | jq -r '.result.envKey')" = "T_DATABASE_ADMIN_URL" ]
  [ "$(echo "$output" | jq -r '.result.envFile')" = ".env.admin.local" ]
  n=$((n + 1))
  # 계획만 — 어떤 레인도 파일을 만들지 않았다(dry-run의 존재 이유).
  [ "$n" -eq 3 ]
  [ ! -e "$T2" ]
  [ ! -e "$BATS_TEST_TMPDIR/.env.local" ]
}
