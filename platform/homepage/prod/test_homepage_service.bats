#!/usr/bin/env bats
# homepage Service(ClusterIP :3000) 가드. @test 이름은 영어.
setup() { S="${BATS_TEST_DIRNAME}/service.yaml"; }

@test "clusterip service exposes port 3000" {
  run grep -q 'kind: Service' "$S"; [ "$status" -eq 0 ]
  run grep -q 'port: 3000' "$S"; [ "$status" -eq 0 ]
  run grep -q 'app.kubernetes.io/name: homepage' "$S"; [ "$status" -eq 0 ]
}
