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
