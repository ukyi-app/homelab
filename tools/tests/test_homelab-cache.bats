#!/usr/bin/env bats
# homelab cache create — 공유 변이 엔진(lib/mutation.ts)의 두 번째 인스턴스.
# 엔진 골격(nonce 특정·race·추적·머지 관측·수렴 판정)의 전 시나리오는 test_homelab-db.bats가
# SSOT로 고정한다 — 여기서는 cache 고유 계약만 단언한다: 디스패처 입력 매핑(name·maxmemory_mi
# 빈 값=디스패처 기본), maxmemory 범위(16..1024), Application 집합(cache-prod·data-conn-prod)
# 전체 수렴 요구, cache url 패스스루 비회귀, 골든 variant 고정.
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
  # cache PR 픽스처 — pulls?head 케이스는 db와 공유라 브랜치만 cache 것으로 덮는다
  printf '[{"number":31,"html_url":"https://github.com/ukyi-app/homelab/pull/31","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/db-prs.json"
}

run_cache_create() {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    "$BUN" tools/homelab.ts cache create mycache --poll-ms 10 --deadline-ms 500 "$@"
}

@test "cache create dispatches the exact contract argv with maxmemory_mi (ledger exact)" {
  run_cache_create --maxmemory-mi 128 --json
  [ "$status" -eq 0 ]
  run python3 "$LEDGER_PY" exact "$CALLS" gh workflow run create-cache.yaml -R ukyi-app/homelab \
    -f "name=mycache" -f "maxmemory_mi=128" -f "correlation=$NONCE"
  [ "$status" -eq 0 ]
}

@test "cache create without --maxmemory-mi sends an empty value (dispatcher default 64 owns it)" {
  run_cache_create --json
  [ "$status" -eq 0 ]
  run python3 "$LEDGER_PY" exact "$CALLS" gh workflow run create-cache.yaml -R ukyi-app/homelab \
    -f "name=mycache" -f "maxmemory_mi=" -f "correlation=$NONCE"
  [ "$status" -eq 0 ]
}

@test "cache create rejects maxmemory outside 16..1024 and a bad name as usage errors" {
  run --separate-stderr env PATH="$STUB" "$BUN" tools/homelab.ts cache create mycache --maxmemory-mi 8 --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr env PATH="$STUB" "$BUN" tools/homelab.ts cache create mycache --maxmemory-mi 2048 --json
  [ "$status" -eq 2 ]
  run --separate-stderr env PATH="$STUB" "$BUN" tools/homelab.ts cache create bad-ro --json
  [ "$status" -eq 2 ]
}

@test "cache create without --wait succeeds on run success with the cache action and PR handle" {
  run_cache_create --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.verb')" = "cache create" ]
  [ "$(echo "$output" | jq -r '.result.action')" = "create-cache" ]
  [ "$(echo "$output" | jq -r '.result.run.id')" = "601" ]
  [ "$(echo "$output" | jq -r '.result.pr.number')" = "31" ]
}

@test "cache create wait requires the FULL cache application set (partial convergence is pending)" {
  printf '[{"number":31,"html_url":"u31","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  printf '{"status":{"sync":{"status":"OutOfSync","revision":"0ldrev1"},"health":{"status":"Progressing"}}}\n' > "$FIX/argocd-data-conn.json"
  printf 'behind\n' > "$FIX/db-compare.txt"
  run_cache_create --wait --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "pending" ]
  [ "$(echo "$output" | jq -r '[.result.applications[].name] | sort | join(",")')" = "cache-prod,data-conn-prod" ]
}

@test "cache create wait succeeds when both cache-prod and data-conn-prod converge" {
  printf '[{"number":31,"html_url":"u31","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  run_cache_create --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '[.result.applications[].name] | sort | join(",")')" = "cache-prod,data-conn-prod" ]
  [ "$(echo "$output" | jq -r '[.result.applications[].surfaceOk] | unique | join(",")')" = "true" ]
  # cache 고유 계약값의 원장 단언 — stub 글롭은 fail-closed 게이트일 뿐, 인자 경계 증명은 원장 몫.
  # 브랜치 명명(_create-cache.yaml SSOT)과 표면 경로(provision-cache 산출)가 오타면 여기서 red.
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/pulls?state=all&head=ukyi-app:create-cache/mycache-601" --jq)" -ge 1 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/contents/platform/cache/prod/mycache/deployment.yaml?ref=feedbee" --jq .sha)" -ge 1 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/contents/platform/data-conn/prod/cache-mycache-conn.sealed.yaml?ref=feedbee" --jq .sha)" -ge 1 ]
}

@test "cache create goldens pin the cache-specific variants and validate against the schema (floor 3)" {
  # 엔진 공유 variant(race·superseded 등)의 골든 SSOT는 db 골든 — 여기서는 cache 고유 결과
  # 필드(action·집합)를 지닌 3종(success/pending/생략)만 고정한다.
  export OUTDIR="$BATS_TEST_TMPDIR"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" "$BUN" tools/homelab.ts cache create mycache --maxmemory-mi 128 --poll-ms 10 --deadline-ms 500 --json > "$OUTDIR/g-success.json" 2>/dev/null || true
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" "$BUN" tools/homelab.ts cache create mycache --poll-ms 10 --deadline-ms 400 --wait --json > "$OUTDIR/g-pending.json" 2>/dev/null || true
  # 생략 골든은 머지 관측까지는 성공해야 한다 — 머지된 PR 픽스처로 배치(아니면 pending으로 오염)
  printf '[{"number":31,"html_url":"https://github.com/ukyi-app/homelab/pull/31","merged_at":"2026-08-20T10:00:00Z","merge_commit_sha":"feedbee"}]\n' > "$FIX/db-prs.json"
  env -u KUBECONFIG PATH="$STUB" HOMELAB_CORRELATION="$NONCE" "$BUN" tools/homelab.ts cache create mycache --poll-ms 10 --deadline-ms 500 --wait --json > "$OUTDIR/g-omitted.json" 2>/dev/null || true
  n=0
  for g in success pending omitted; do
    diff -u "tools/tests/fixtures/homelab/cache-create-$g.golden.json" "$OUTDIR/g-$g.json"
    n=$((n+1))
  done
  [ "$n" -eq 3 ]
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const g of ["success", "pending", "omitted"]) {
      const env = JSON.parse(readFileSync("tools/tests/fixtures/homelab/cache-create-" + g + ".golden.json", "utf8"));
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(g + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:3$"
}

@test "a db-create envelope with the cache action is schema-rejected (verb-action coupling)" {
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    const env = JSON.parse(readFileSync("tools/tests/fixtures/homelab/db-create-success.golden.json", "utf8"));
    env.result = { ...env.result, action: "create-cache" };
    console.log(schemaErrors(env, sch, sch).length > 0 ? "rejected" : "ACCEPTED");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^rejected$"
}

@test "cache url is a catalog op: --json yields a schema-valid envelope with no plaintext value" {
  # 구 byte-parity는 catalog 승격으로 계약이 대체됐다(티켓 08) — op envelope 계약 + 렌더러 소유.
  export OUTDIR="$BATS_TEST_TMPDIR"
  run --separate-stderr bun tools/homelab.ts cache url --name t --dry-run --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verb')" = "cache url" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.dryRun')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.mode')" = "readonly" ]
  [ "$(printf '%s' "$output" | grep -c "redis://")" = "0" ]
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

@test "cache create --help prints the verb usage and exits 0" {
  run bun tools/homelab.ts cache create --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--maxmemory-mi"
  echo "$output" | grep -q -- "--wait"
}
