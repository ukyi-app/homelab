#!/usr/bin/env bats
# homepage Deployment(restricted·ALLOWED_HOSTS·디렉토리 마운트) 가드. @test 이름은 영어.
setup() { D="${BATS_TEST_DIRNAME}/deployment.yaml"; }

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
  run grep -qE 'memory:\s*128Mi' "$D"; [ "$status" -eq 0 ]
}

@test "config mounts as a directory without subPath so updates propagate" {
  # F3: subPath '필드' 금지(갱신 미전파) — 주석 단어가 아니라 'subPath:' 키만 검사.
  run grep -qE '^[[:space:]]*subPath:' "$D"; [ "$status" -ne 0 ]
  run grep -qE 'mountPath: /app/config\b' "$D"; [ "$status" -eq 0 ]
}
