#!/usr/bin/env bats
# files Deployment 회귀 가드. @test 이름은 영어.
D="$BATS_TEST_DIRNAME/deployment.yaml"

@test "deployment uses Recreate strategy (RWO PVC)" {
  run yq '.spec.strategy.type' "$D"; [ "$output" = "Recreate" ]
}

@test "container is restricted: readOnlyRootFilesystem + drop ALL + non-root" {
  run yq '.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' "$D"; [ "$output" = "true" ]
  run yq '.spec.template.spec.containers[0].securityContext.capabilities.drop[0]' "$D"; [ "$output" = "ALL" ]
  run yq '.spec.template.spec.securityContext.runAsNonRoot' "$D"; [ "$output" = "true" ]
}

@test "pod fsGroup 65532 lets non-root write /data" {
  run yq '.spec.template.spec.securityContext.fsGroup' "$D"; [ "$output" = "65532" ]
}

@test "two container ports 8080 and 8081" {
  run yq '[.spec.template.spec.containers[0].ports[].containerPort] | sort | join(",")' "$D"
  [ "$output" = "8080,8081" ]
}

@test "keys secret is mounted as a FILE, not envFrom" {
  run yq '.spec.template.spec.containers[0].volumeMounts[] | select(.mountPath=="/etc/files-keys") | .readOnly' "$D"
  [ "$output" = "true" ]
  run yq '.spec.template.spec.containers[0].envFrom' "$D"; [ "$output" = "null" ]
}

@test "FILES_KEYS_PATH points at the mounted file" {
  run yq '.spec.template.spec.containers[0].env[] | select(.name=="FILES_KEYS_PATH") | .value' "$D"
  [ "$output" = "/etc/files-keys/keys.json" ]
}

@test "resource requests(cpu+mem) + memory limit present (CI gate)" {
  run yq '.spec.template.spec.containers[0].resources.requests.cpu' "$D"; [ "$output" != "null" ]
  run yq '.spec.template.spec.containers[0].resources.requests.memory' "$D"; [ "$output" != "null" ]
  run yq '.spec.template.spec.containers[0].resources.limits.memory' "$D"; [ "$output" != "null" ]
}

@test "imagePullSecrets ghcr-pull + no SA token" {
  run yq '.spec.template.spec.imagePullSecrets[0].name' "$D"; [ "$output" = "ghcr-pull" ]
  run yq '.spec.template.spec.automountServiceAccountToken' "$D"; [ "$output" = "false" ]
}

@test "probes hit internal :8080 (public :8081 has no health handler)" {
  run yq '.spec.template.spec.containers[0].readinessProbe.httpGet.port' "$D"; [ "$output" = "internal" ]
  run yq '.spec.template.spec.containers[0].livenessProbe.httpGet.path' "$D"; [ "$output" = "/healthz" ]
}

@test "image is digest-pinned (@sha256:) — immutable, not a bare mutable tag" {
  run yq '.spec.template.spec.containers[0].image' "$D"
  [[ "$output" == *"@sha256:"* ]]
}
