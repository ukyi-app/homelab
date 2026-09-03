#!/usr/bin/env bats
# Glances host-introspection Deployment 보안 경계 가드(A.5·Pass2). @test 이름은 영어.
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 glances.yaml 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a
setup() { G="${BATS_TEST_DIRNAME}/glances.yaml"; }

@test "glances runs strict nonroot with caps dropped (A.5 hardening)" {
  run grep -q 'runAsNonRoot: true' "$G"; [ "$status" -eq 0 ]
  run grep -qE 'runAsUser: 65534' "$G"; [ "$status" -eq 0 ]
  run grep -q 'allowPrivilegeEscalation: false' "$G"; [ "$status" -eq 0 ]
  run grep -qE 'drop:\s*\[?\s*"?ALL"?' "$G"; [ "$status" -eq 0 ]
}

@test "glances does not mount the host root filesystem by default (A.5 minimal mounts)" {
  # ⚠️ 이 @test는 부재 단언 둘뿐이라 형제 증인이 없다 — 예전 `-ne 0`에서는 glances.yaml을 리네임해도
  #    초록이었다(2026-08-29 격리 트리 실측: 5개 중 생존 2건 — 이 @test와, 피연산자가 다른 파일
  #    (glances-netpol.yaml)인 @test 5. glances.yaml을 읽는 넷 중에서는 이 @test가 유일한 생존자다).
  #    hostPID를 쥔 워크로드의 마운트 경계 검사가 대상 부재에 공허했다는 뜻이다.
  # ⚠️ **표기 회피 축**(2026-09-03 실측): 두 정규식은 특정 표기 둘만 봤다 — 패턴1은 `/` 직후 `}`를
  #    요구해 `, type: Directory`에 깨지고, 패턴2의 `$` 앵커는 flow 매핑 줄끝이 ` } }`라 불성립.
  #    그래서 이 파일이 **이미 쓰는 flow 관례 그대로** host root를 붙이면
  #    (`- { name: hostroot, hostPath: { path: /, type: Directory } }`) 5/5 초록이었다.
  #    검출기가 자기 도메인의 표기법에 눈이 먼 형태다(cf. docs/traps-detail.md 「ERE의 leftmost-longest…」).
  #    ⇒ 표기가 아니라 **파싱한 hostPath 경로 열거**로 판정한다(형제 test_pvc_du_exporter.bats:31-35 관례).
  # `select(.kind==…)` 필터는 넣지 않는다 — Service 문서는 `.spec.template`가 없어 빈 출력이고(rc 0),
  # 필터를 넣으면 DaemonSet 전환 시 분모가 조용히 빈다. 그 축은 아래 `[ -n "$paths" ]`가 닫는다.
  paths="$(yq -e '.spec.template.spec.volumes[] | select(.hostPath) | .hostPath.path' "$G")"
  [ -n "$paths" ]   # 양성 대조 — 열거가 비면 아래 부재 판정이 공허하다
  run grep -qxF -- '/' <<EOF
$paths
EOF
  [ "$status" -eq 1 ]
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
