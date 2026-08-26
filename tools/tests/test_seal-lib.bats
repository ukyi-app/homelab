#!/usr/bin/env bats
# kubeseal 봉인 SSOT(tools/lib/seal.ts) — 평문은 stdin으로만, 디스크/stdout 비기록.
# ⚠️ 중간 단언은 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "seal.ts exports sealManifest and fails loud on missing cert" {
  run bun -e '
    import { sealManifest } from "./tools/lib/seal.ts";
    try { sealManifest({ kind: "Secret" }, "/nonexistent/cert.pem"); console.log("DID-NOT-THROW"); }
    catch (e) { console.log("threw"); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^threw$"
}

@test "provision callsites use sealManifest (no inline kubeseal spawnSync left)" {
  run grep -nE 'spawnSync\("kubeseal"' tools/provision-db.ts tools/provision-cache.ts
  [ "$status" -ne 0 ]
  for f in provision-db.ts provision-cache.ts; do
    run grep -q "lib/seal.ts" "tools/$f"
    [ "$status" -eq 0 ]
  done
}

@test "app-shared seal-secret.mts keeps its own kubeseal block (NOT migrated, F3)" {
  # 외부 앱 레포 배포 self-contained — homelab lib import 금지
  run grep -nE 'spawnSync\("kubeseal"' tools/seal-secret.mts
  [ "$status" -eq 0 ]
  run grep -q "lib/seal" tools/seal-secret.mts
  [ "$status" -ne 0 ]
}

@test "a kubeseal failure surfaces the exit code but never the child stderr (plaintext echo defence)" {
  # d6④ 이관면의 성질 고정 — 실패 메시지에 stderr(res.err)를 싣지 않는다. kubeseal이 평문을 stderr로
  # 에코하는 최악 상황을 스텁으로 재현해, 그 평문이 throw 메시지에 실리지 않음을 실측한다
  # (15행 분기에 ${res.err}를 붙이는 mutation이 이 단언에서 red가 된다).
  S="$BATS_TEST_TMPDIR/bin"; mkdir -p "$S"
  printf '#!/bin/sh\necho "PLAINTEXT-ECHO-9d2c $(cat)" >&2\nexit 1\n' > "$S/kubeseal"
  chmod +x "$S/kubeseal"
  run env PATH="$S:$PATH" bun -e '
    import { sealManifest } from "./tools/lib/seal.ts";
    try { sealManifest({ kind: "Secret", stringData: { K: "PLAINTEXT-ECHO-9d2c" } }, "/tmp/cert.pem"); console.log("DID-NOT-THROW"); }
    catch (e) { console.log("threw: " + (e as Error).message); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^threw: '
  echo "$output" | grep -q '종료 코드 1'
  run grep -q 'PLAINTEXT-ECHO-9d2c' <<<"$output"
  [ "$status" -ne 0 ]
}
