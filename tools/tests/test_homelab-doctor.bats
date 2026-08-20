#!/usr/bin/env bats
# homelab doctor — 플랫폼 전제 진단의 프로세스 경계 계약.
# 하네스: PATH stub(gh + 시스템 도구 심링크) + argv 원장(NUL 구분·RS 종단) — helpers/cli_stub.bash.
# 네트워크 0: gh 응답은 전부 stub이 낸다. 골든 JSON은 tools/tests/fixtures/homelab/이 SSOT이고
# 스키마 검증은 test_homelab-cli.bats(계약)와 이 파일(골든)이 나눠 가진다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(인코딩 함정).
bats_require_minimum_version 1.5.0
load "helpers/cli_stub"

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  cd "$ROOT" || exit 1
  cli_stub_init
  make_gh_stub
  make_kubeseal_stub
  KC="$BATS_TEST_TMPDIR/kubeconfig"
  echo "apiVersion: v1" > "$KC"
}

@test "doctor human mode reports every check with a status mark on stdout and exits 0 when green" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor
  [ "$status" -eq 0 ]
  n=0
  for id in gh-auth gh-owner gh-scopes bun kubeseal kubeconfig template-access template-scaffold-contract template-targetarch; do
    echo "$output" | grep -q "^✓ $id"
    n=$((n+1))
  done
  # 열거 바닥값: 점검 9항목 전부 확인(루프 붕괴 → vacuous green 차단)
  [ "$n" -eq 9 ]
  echo "$output" | grep -q "진단 결과"
}

@test "doctor --json emits exactly one schema-valid object on stdout with human text on stderr" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
  [ "$(echo "$output" | jq -r '.exitCode')" = "$status" ]
  [ "$(echo "$output" | jq -r '.result.checks | length')" = "9" ]
  [ "$(echo "$output" | jq -r '[.result.checks[].status] | unique | join(",")')" = "pass" ]
  echo "$stderr" | grep -q "진단 결과"
}

@test "doctor --json all-green output matches the golden success fixture byte-for-byte" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/actual.json"
  diff -u tools/tests/fixtures/homelab/doctor-success.golden.json "$BATS_TEST_TMPDIR/actual.json"
}

@test "doctor --json failure scenario matches golden and exits 1 (owner mismatch, kubeseal missing, fullstack un-parameterized, KUBECONFIG unset)" {
  rm -f "$STUB/kubeseal"
  printf 'FROM oven/bun:1\nRUN bun build --compile --target=bun-linux-arm64\n' > "$FIX/Dockerfile.fullstack"
  run --separate-stderr env -u KUBECONFIG PATH="$STUB" STUB_OWNER="other-owner" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -s 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.variant')" = "failure" ]
  [ "$(echo "$output" | jq -r '.exitCode')" = "$status" ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-owner") | .status')" = "fail" ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="kubeseal") | .status')" = "fail" ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="kubeconfig") | .status')" = "warn" ]
  echo "$output" | jq -r '.result.checks[] | select(.id=="template-targetarch") | .detail' | grep -q "fullstack"
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/actual.json"
  diff -u tools/tests/fixtures/homelab/doctor-failure.golden.json "$BATS_TEST_TMPDIR/actual.json"
}

@test "golden fixtures validate against the checked-in result schema (envelope + doctorResult, floor 2)" {
  run bun -e '
    import { schemaErrors } from "./tools/lib/schema-check.ts";
    import { readFileSync } from "node:fs";
    const sch = JSON.parse(readFileSync("tools/cli-result-schema.json", "utf8"));
    let n = 0;
    for (const f of ["doctor-success", "doctor-failure"]) {
      const env = JSON.parse(readFileSync("tools/tests/fixtures/homelab/" + f + ".golden.json", "utf8"));
      const errs = [
        ...schemaErrors(env, sch, sch),
        ...schemaErrors(env.result, sch.definitions.doctorResult, sch),
      ];
      if (errs.length) { console.error(f + ": " + errs.join(" | ")); process.exit(1); }
      n++;
    }
    console.log("ok:" + n);
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:2$"
}

@test "gh auth failure fail-closes dependent checks without further gh calls" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_GH_UNAUTH=1 "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-auth") | .status')" = "fail" ]
  n=0
  for id in gh-owner gh-scopes template-access template-scaffold-contract template-targetarch; do
    [ "$(echo "$output" | jq -r --arg id "$id" '.result.checks[] | select(.id==$id) | .status')" = "fail" ]
    echo "$output" | jq -r --arg id "$id" '.result.checks[] | select(.id==$id) | .detail' | grep -q "판정 불가"
    n=$((n+1))
  done
  [ "$n" -eq 5 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "1" ]
}

@test "missing scopes header degrades to warn (fine-grained PAT is statically undecidable)" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_NO_SCOPES_HEADER=1 "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-scopes") | .status')" = "warn" ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
}

@test "insufficient token scopes fail naming the missing ones" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_SCOPES="gist, read:org" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-scopes") | .status')" = "fail" ]
  echo "$output" | jq -r '.result.checks[] | select(.id=="gh-scopes") | .detail' | grep -q "repo"
  echo "$output" | jq -r '.result.checks[] | select(.id=="gh-scopes") | .detail' | grep -q "workflow"
}

@test "empty HOMELAB_OWNER variable fails closed (actor-guard parity)" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_OWNER="" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="gh-owner") | .status')" = "fail" ]
}

@test "KUBECONFIG pointing at a missing file is a fail (misconfiguration, not omission)" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$BATS_TEST_TMPDIR/no-such-file" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="kubeconfig") | .status')" = "fail" ]
}

@test "template repo that is not a template fails template-access" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" STUB_IS_TEMPLATE=false "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="template-access") | .status')" = "fail" ]
}

@test "scaffolder without the non-interactive contract markers fails template-scaffold-contract" {
  printf 'const interactiveOnly = true;\n' > "$FIX/scaffold.ts"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | jq -r '.result.checks[] | select(.id=="template-scaffold-contract") | .status')" = "fail" ]
}

@test "doctor is observation-only: every gh call is a read (no mutation-shaped argv)" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  run python3 "$LEDGER_PY" gh-readonly "$CALLS"
  [ "$status" -eq 0 ]
}

@test "doctor fetches exactly 4 template files and never the site Dockerfile (arch-neutral exclusion)" {
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" tools/homelab.ts doctor --json
  [ "$status" -eq 0 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api repos/ukyi-app/homelab-app-template/contents/scaffold/scaffold.ts --jq .content)" = "1" ]
  n=0
  for a in api fullstack worker; do
    c="$(python3 "$LEDGER_PY" count "$CALLS" gh api "repos/ukyi-app/homelab-app-template/contents/scaffold/archetypes/$a/Dockerfile" --jq .content)"
    [ "$c" = "1" ]
    n=$((n+1))
  done
  [ "$n" -eq 3 ]
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh api repos/ukyi-app/homelab-app-template/contents/scaffold/archetypes/site/Dockerfile --jq .content)" = "0" ]
  # 총 호출 상한 겸 바닥값: user 1 + owner 변수 1 + 템플릿 메타 1 + 컨텐츠 4 = 7 (미지의 추가 호출 차단)
  [ "$(python3 "$LEDGER_PY" count "$CALLS" gh)" = "7" ]
}

@test "doctor works from outside the repository (resolves its own location)" {
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr env PATH="$STUB" KUBECONFIG="$KC" "$BUN" "$ROOT/tools/homelab.ts" doctor --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.variant')" = "success" ]
}
