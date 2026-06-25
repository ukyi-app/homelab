#!/usr/bin/env bats
# app-shared .mts(seal-secret·env-example)가 bun 없이 node strip-types(앱 레포 secret:seal 경로)에서도
# 실행됨을 required gate가 보장하는지 검증 (A.5 F1·pass3). ⚠️ 중간 단언은 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "smoke runs inside the required gate job, not a separate job (A.5 pass3 F1)" {
  [ -x tests/gates/app-shared-node-smoke.sh ]
  run grep -E 'seal-secret\.mts' tests/gates/app-shared-node-smoke.sh; [ "$status" -eq 0 ]
  run grep -E 'env-example\.mts' tests/gates/app-shared-node-smoke.sh; [ "$status" -eq 0 ]
  # required check는 gate 잡뿐 — 스모크는 gate 안 스텝이어야(별도 잡이면 비-required라 무성 회귀)
  run grep -F 'app-shared-node-smoke.sh' .github/workflows/ci.yaml; [ "$status" -eq 0 ]
  run grep -E '^  app-shared-node-smoke:' .github/workflows/ci.yaml; [ "$status" -ne 0 ]
}

@test "env-example no longer scaffolds _DATABASE_URL/_REDIS_URL (connection is a sealed secret)" {
  tmp="$BATS_TEST_TMPDIR/ee"; mkdir -p "$tmp"
  # db/redis가 raw로 들어와도(구계약) URL 스캐폴드를 만들지 않아야 — secrets만 유도.
  printf 'kind: service\nsecrets: [token]\ndb: [orders]\nredis: [sessions]\n' > "$tmp/.app-config.yml"
  run bun "$ROOT/tools/env-example.mts" --config "$tmp/.app-config.yml" --out "$tmp/.env.example"
  [ "$status" -eq 0 ]
  run grep -qE '_DATABASE_URL|_REDIS_URL' "$tmp/.env.example"
  [ "$status" -ne 0 ]
  run grep -q 'TOKEN=' "$tmp/.env.example"
  [ "$status" -eq 0 ]
}

@test "smoke actually runs the .mts under node when node>=22.18 is available" {
  command -v node >/dev/null || skip "node 미설치 — CI에서 검증"
  ver=$(node --version); ver=${ver#v}
  major=${ver%%.*}; minor=$(printf '%s' "$ver" | cut -d. -f2)
  { [ "$major" -gt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -ge 18 ]; }; } || skip "node<22.18 — strip-types 미지원"
  run bash tests/gates/app-shared-node-smoke.sh
  [ "$status" -eq 0 ]
}
