#!/usr/bin/env bats
# homepage Deployment(restricted·ALLOWED_HOSTS·디렉토리 마운트) 가드. @test 이름은 영어.
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 deployment.yaml 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
setup() {
  D="${BATS_TEST_DIRNAME}/deployment.yaml"
  LEDGER="${BATS_TEST_DIRNAME}/../../../docs/memory-ledger.md"
}

@test "uses the gethomepage image and container port 3000" {
  run grep -q 'ghcr.io/gethomepage/homepage' "$D"; [ "$status" -eq 0 ]
  run grep -q 'containerPort: 3000' "$D"; [ "$status" -eq 0 ]
}

@test "HOMEPAGE_ALLOWED_HOSTS includes the internal host and pod IP" {
  run grep -q 'HOMEPAGE_ALLOWED_HOSTS' "$D"; [ "$status" -eq 0 ]
  run grep -q 'dash.home.ukyi.app' "$D"; [ "$status" -eq 0 ]
  run grep -q 'MY_POD_IP' "$D"; [ "$status" -eq 0 ]
}

@test "container security context is PSA restricted compliant" {
  run grep -q 'runAsNonRoot: true' "$D"; [ "$status" -eq 0 ]
  run grep -q 'allowPrivilegeEscalation: false' "$D"; [ "$status" -eq 0 ]
  run grep -q 'seccompProfile' "$D"; [ "$status" -eq 0 ]
  run grep -qE 'drop:\s*\[?\s*("?ALL"?)' "$D"; [ "$status" -eq 0 ]
}

@test "binds the homepage serviceaccount" {
  run grep -q 'serviceAccountName: homepage' "$D"; [ "$status" -eq 0 ]
}

@test "declares resource limits matching the ledger" {
  run grep -qE 'limits:' "$D"; [ "$status" -eq 0 ]
  # ⚠️ 원장 값을 **읽어서** 대조한다. 상수를 박으면 이 @test는 이름과 달리 원장을 안 보고,
  #    원장이 정정될 때마다 무관한 red를 낸다(2026-09-01: 192→208 정정에서 실제로 그랬다).
  local want
  want="$(awk -F'|' '/ledger:row --> homepage /{gsub(/[^0-9]/, "", $5); print $5}' "$LEDGER")"
  [ -n "$want" ]
  run grep -qE "memory:[[:space:]]*${want}Mi" "$D"; [ "$status" -eq 0 ]
}

@test "config is a writable emptyDir seeded by initContainer (EROFS regression guard)" {
  # /app/config RO 마운트는 gethomepage skeleton copyfile을 EROFS로 막아 CrashLoop → 금지.
  run grep -q 'name: seed-config' "$D"; [ "$status" -eq 0 ]
  run grep -q 'emptyDir: {}' "$D"; [ "$status" -eq 0 ]
  run grep -q 'name: config-src' "$D"; [ "$status" -eq 0 ]
  # subPath 금지가 이 @test의 유일한 부재 단언이다 — 형제 양성 단언(seed-config·emptyDir·config-src)이
  # 같은 파일을 들므로 대상 부재는 이미 red지만, 형제가 리팩터로 빠지면 그때부터 홀로 공허해진다.
  run grep -qE '^[[:space:]]*subPath:' "$D"; [ "$status" -eq 1 ]
  run grep -qE 'mountPath: /app/config\b' "$D"; [ "$status" -eq 0 ]
}

@test "assets configmap is mounted read-only at public images (no subPath)" {
  # 로고/배경 자산을 /app/public/images에 디렉토리 RO 마운트(subPath 금지 가드와 양립).
  run grep -qE 'mountPath: /app/public/images\b' "$D"; [ "$status" -eq 0 ]
  run grep -q 'name: assets' "$D"; [ "$status" -eq 0 ]
  run grep -q 'homepage-assets' "$D"; [ "$status" -eq 0 ]
}
