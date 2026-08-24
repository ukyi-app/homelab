#!/usr/bin/env bats
# homelab app secrets — 이중 모드 변이의 프로세스 경계 계약.
# 앱 레포 안(마커 .app-config.yml + canonical remote): 선행 조건(main·클린 트리·canonical) 전부 통과해야
# seal(벤더 tools/seal-secret.mts 위임)→봉인본만 커밋→push→원격 main 도달성 증명→update-secrets
# 디스패치. 하나라도 실패면 **디스패치 없이** 거부. 밖: 디스패치만. 재실행 수렴은 --no-seal(재봉인 없이
# 이미 커밋·push된 봉인본을 재디스패치 — kubeseal 암호문은 매번 달라 "재봉인 후 동일성"으로는 수렴
# 불가). no-op: run 성공 + PR 0 = 정당한 no-op,
# --wait 검증은 main 기준 표면 blob 동치(머지 SHA·PR 요구 없음). 평문 값은 어떤 채널에도 없다.
# 심: 앱 레포 = 임시 실물 git 레포(helpers make_app_repo_fixture), 외부 명령 = PATH stub + NUL 원장.
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
  make_app_repo_fixture myapp
  # update-secrets 브랜치 PR(미머지) — pulls?head 케이스는 공유라 파일만 덮는다
  printf '[{"number":41,"html_url":"https://github.com/ukyi-app/homelab/pull/41","merged_at":null,"merge_commit_sha":null}]\n' > "$FIX/db-prs.json"
}

# cwd를 인자로 받는 호출 — SEAL_VERSION 기본 2(갱신 경로)
run_secrets_in() {
  dir="$1"; shift
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" \
    bash -c "cd '$dir' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 $*"
}

@test "in-repo chain: seal, commit only the sealed file, push, prove reachability, then dispatch" {
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.verb')" = "app secrets" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.chain.mode')" = "chain" ]
  [ "$(echo "$output" | jq -r '.result.chain.pushed')" = "true" ]
  # 커밋은 봉인본 파일만 — 원격 main이 로컬 HEAD와 같다(도달성)
  [ "$(git -C "$APP_WORK" show --name-only --format= HEAD)" = "deploy/myapp-secrets.sealed.yaml" ]
  [ "$(git -C "$APP_REMOTE" rev-parse main)" = "$(git -C "$APP_WORK" rev-parse HEAD)" ]
  [ "$(echo "$output" | jq -r '.result.chain.headSha')" = "$(git -C "$APP_WORK" rev-parse HEAD)" ]
  [ "$(echo "$output" | jq -r '.result.chain.sealSkipped')" = "false" ]
  # seal 위임 argv = 벤더 도구 계약(tools/README.md seal-secret.mts 절) 그대로 — 드리프트면 red
  run python3 "$LEDGER_PY" exact "$CALLS" seal-secret --config .app-config.yml --env .env --app myapp
  [ "$status" -eq 0 ]
  run python3 "$LEDGER_PY" exact "$CALLS" gh workflow run update-secrets.yaml -R ukyi-app/homelab -f "app=myapp" -f "correlation=$NONCE"
  [ "$status" -eq 0 ]
}

@test "chain-mode success and precondition refusal envelopes validate against the schema (floor 2)" {
  export OUTDIR="$BATS_TEST_TMPDIR"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" bash -c "cd '$APP_WORK' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json" > "$OUTDIR/chain.json" 2>/dev/null || true
  printf 'junk\n' > "$APP_WORK/scratch.txt"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" bash -c "cd '$APP_WORK' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json" > "$OUTDIR/refused.json" 2>/dev/null || true
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const f of ["chain", "refused"]) {
      const env = JSON.parse(readFileSync(process.env.OUTDIR + "/" + f + ".json", "utf8"));
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(f + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:2$"
}

@test "a dirty tree is refused before seal and before dispatch" {
  printf 'junk\n' > "$APP_WORK/scratch.txt"
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  echo "$output" | jq -r '.result.error' | grep -q "깨끗"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
}

@test "a non-main branch is refused without dispatch" {
  git -C "$APP_WORK" checkout -q -b feature/x
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' | grep -q "main"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
}

@test "an app-looking repo with a non-canonical remote is refused fail-closed (no dispatch)" {
  git -C "$APP_WORK" remote set-url origin https://github.com/ukyi-app/otherapp.git
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' | grep -q "canonical"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "0" ]
}

@test "outside an app repo (no marker) only the dispatch runs — no seal, no git mutation" {
  run_secrets_in "$APPS_ROOT" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.chain.mode')" = "dispatch-only" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "0" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "1" ]
  # 마커 없는 git 레포(homelab 디렉토리류)도 디스패치만
  OTHER="$BATS_TEST_TMPDIR/other-repo"; git init -q "$OTHER"
  run_secrets_in "$OTHER" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.chain.mode')" = "dispatch-only" ]
}

@test "push succeeded but dispatch failed: rerun with --no-seal converges by dispatching only (no second commit)" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" STUB_GH_DISPATCH_FAIL=1 \
    bash -c "cd '$APP_WORK' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json"
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.result.chain.pushed')" = "true" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "2" ]
  run_secrets_in "$APP_WORK" --no-seal --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.result.chain.sealSkipped')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.chain.pushed')" = "false" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "2" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" seal-secret)" = "1" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "2" ]
}

@test "rerunning WITH reseal is never a silent no-op: a fresh ciphertext means a new commit (reality of kubeseal)" {
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 0 ]
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.chain.pushed')" = "true" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "3" ]
}

@test "--no-seal without a committed sealed secret is refused without dispatch" {
  git -C "$APP_WORK" rm -q deploy/myapp-secrets.sealed.yaml
  git -C "$APP_WORK" commit -q -m "drop sealed"
  git -C "$APP_WORK" push -q origin main
  run_secrets_in "$APP_WORK" --no-seal --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -r '.result.error' | grep -q -- "--no-seal"
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh workflow run)" = "0" ]
}

@test "an already-wired sealed secret (--no-seal, dispatcher reports no change) is a no-op: exit 0, no PR, no merge SHA" {
  printf '[]\n' > "$FIX/db-prs.json"
  run_secrets_in "$APP_WORK" --no-seal --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "no-op" ]
  [ "$(echo "$output" | jq -r '.result | has("pr")')" = "false" ]
  [ "$(echo "$output" | jq -r '.result.chain.pushed')" = "false" ]
  [ "$(git -C "$APP_REMOTE" rev-list --count main)" = "1" ]
}

@test "no-op with --wait verifies the surface against main at the synced revision (no merge SHA required)" {
  printf '[]\n' > "$FIX/db-prs.json"
  run_secrets_in "$APPS_ROOT" --wait --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "no-op" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].name')" = "myapp-prod" ]
  [ "$(echo "$output" | jq -r '.result.applications[0].surfaceOk')" = "true" ]
  [ "$(echo "$output" | jq -r '.result.applications[0] | has("descendant")')" = "false" ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab/contents/apps/myapp/deploy/prod/myapp-secrets.sealed.yaml?ref=main" --jq .sha)" -ge 1 ]
}

@test "no-op with --wait and no KUBECONFIG omits the live section (exit 0)" {
  printf '[]\n' > "$FIX/db-prs.json"
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" HOMELAB_CORRELATION="$NONCE" \
    bash -c "cd '$APPS_ROOT' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --wait --json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "no-op" ]
  [ "$(echo "$output" | jq -r '.omitted | join(",")')" = "live" ]
}

@test "the secret value never appears on stdout, stderr, or the argv ledger" {
  run_secrets_in "$APP_WORK" --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c "$CANARY")" = "0" ]
  [ "$(printf '%s' "$stderr" | grep -c "$CANARY")" = "0" ]
  [ "$(grep -c "$CANARY" "$CALLS")" = "0" ]
  # 바닥값: 평문 파일에는 실제로 카나리가 있다(단언이 빈 파일을 검사하는 vacuous green 차단)
  [ "$(grep -c "$CANARY" "$APP_WORK/.env")" = "1" ]
}

@test "app secrets goldens pin success, no-op, and omitted variants and validate against the schema (floor 3)" {
  export OUTDIR="$BATS_TEST_TMPDIR"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" bash -c "cd '$APPS_ROOT' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json" > "$OUTDIR/g-success.json" 2>/dev/null || true
  printf '[]\n' > "$FIX/db-prs.json"
  env PATH="$STUB" KUBECONFIG="$KC" HOMELAB_CORRELATION="$NONCE" bash -c "cd '$APPS_ROOT' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --json" > "$OUTDIR/g-noop.json" 2>/dev/null || true
  env -u KUBECONFIG PATH="$STUB" HOMELAB_CORRELATION="$NONCE" bash -c "cd '$APPS_ROOT' && exec '$BUN' '$ROOT/tools/homelab.ts' app secrets myapp --poll-ms 10 --deadline-ms 500 --wait --json" > "$OUTDIR/g-omitted.json" 2>/dev/null || true
  n=0
  for g in success noop omitted; do
    diff -u "tools/tests/fixtures/homelab/app-secrets-$g.golden.json" "$OUTDIR/g-$g.json"
    n=$((n+1))
  done
  [ "$n" -eq 3 ]
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const g of ["success", "noop", "omitted"]) {
      const env = JSON.parse(readFileSync("tools/tests/fixtures/homelab/app-secrets-" + g + ".golden.json", "utf8"));
      const errs = schemaErrors(env, sch, sch);
      if (errs.length) { console.error(g + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:3$"
}

@test "app secrets rejects a bad app name as a usage error and prints usage on --help" {
  run --separate-stderr env PATH="$STUB" "$BUN" tools/homelab.ts app secrets "Bad_Name" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run bun tools/homelab.ts app secrets --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--wait"
}
