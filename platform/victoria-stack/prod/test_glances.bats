#!/usr/bin/env bats
# Glances host-introspection Deployment 보안 경계 가드(A.5·Pass2). @test 이름은 영어.
setup() { G="${BATS_TEST_DIRNAME}/glances.yaml"; }

@test "glances runs strict nonroot with caps dropped (A.5 hardening)" {
  run grep -q 'runAsNonRoot: true' "$G"; [ "$status" -eq 0 ]
  run grep -qE 'runAsUser: 65534' "$G"; [ "$status" -eq 0 ]
  run grep -q 'allowPrivilegeEscalation: false' "$G"; [ "$status" -eq 0 ]
  run grep -qE 'drop:\s*\[?\s*"?ALL"?' "$G"; [ "$status" -eq 0 ]
}

@test "glances does not mount the host root filesystem by default (A.5 minimal mounts)" {
  run grep -qE 'hostPath:\s*\{\s*path:\s*/\s*\}' "$G"; [ "$status" -ne 0 ]
  run grep -qE 'path:\s*/$' "$G"; [ "$status" -ne 0 ]
}

@test "glances serves the api on 61208 in observability" {
  run grep -q 'containerPort: 61208' "$G"; [ "$status" -eq 0 ]
  run grep -q 'namespace: observability' "$G"; [ "$status" -eq 0 ]
  run grep -q 'hostPID: true' "$G"; [ "$status" -eq 0 ]
}

@test "glances does not mount a kubernetes api token (Pass2 hardening)" {
  run grep -q 'automountServiceAccountToken: false' "$G"; [ "$status" -eq 0 ]
}

@test "glances ingress is restricted to the homepage namespace (A.5 isolation)" {
  N="${BATS_TEST_DIRNAME}/glances-netpol.yaml"
  run grep -q 'kind: NetworkPolicy' "$N"; [ "$status" -eq 0 ]
  run grep -q 'app.kubernetes.io/name: glances' "$N"; [ "$status" -eq 0 ]
  run grep -q 'kubernetes.io/metadata.name: homepage' "$N"; [ "$status" -eq 0 ]
  run grep -q '61208' "$N"; [ "$status" -eq 0 ]
}
