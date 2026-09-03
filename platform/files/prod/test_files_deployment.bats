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

@test "two container ports 8080 and 8081, each bound to its own name" {
  run yq '[.spec.template.spec.containers[0].ports[].containerPort] | sort | join(",")' "$D"
  [ "$output" = "8080,8081" ]
  # 이름↔번호 결속 — service.yaml이 targetPort를 **이름**으로 참조하고(`internal`/`public`) 여기서
  # 번호로 푼다. 번호 집합만 세면 두 이름을 맞바꿔도 세 조각(HTTPRoute→Service 포트, Service
  # targetPort 이름, 컨테이너 포트 번호)이 전부 개별적으로 참인 채 조인만 끊긴다(실측 2026-09-03:
  # 이름 스왑 후 platform/files/prod 33/33 ok).
  # ⚠️ 이건 **위생 가드**이지 공개 경계가 아니다 — 스왑하면 probe도 같은 이름을 따라가 8081(health
  #    핸들러 없음)을 쳐서 CrashLoop → WorkloadUnavailable로 착지한다. 즉 fail-closed·loud다.
  run yq '.spec.template.spec.containers[0].ports[] | select(.name=="public") | .containerPort' "$D"
  [ "$output" = "8081" ]
  run yq '.spec.template.spec.containers[0].ports[] | select(.name=="internal") | .containerPort' "$D"
  [ "$output" = "8080" ]
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

@test "probes: readiness /readyz, liveness /healthz, both on internal :8080" {
  run yq '.spec.template.spec.containers[0].readinessProbe.httpGet.port' "$D"; [ "$output" = "internal" ]
  run yq '.spec.template.spec.containers[0].livenessProbe.httpGet.path' "$D"; [ "$output" = "/healthz" ]
  # /readyz는 스토리지 저하 검출기다 — pvc.yaml의 방어 4종 중 하나이고, core.yaml의
  # WorkloadUnavailable·r4-storage-backup.yaml의 description이 사람을 이 경로로 보낸다.
  # liveness(/healthz)와 **달라야** 한다: 같아지면 readiness가 프로세스 생존 판정으로 강등된다
  # (실측 2026-09-03: /readyz→/healthz 치환 후에도 platform/files/prod 33/33 ok였다).
  # ⚠️ 경로 문자열만 고정할 뿐이다 — /readyz의 실질(=/data 실제 write + free-space)은 앱 레포
  #    소관이라 여기서 증인할 수 없다.
  run yq '.spec.template.spec.containers[0].readinessProbe.httpGet.path' "$D"; [ "$output" = "/readyz" ]
}

@test "image is digest-pinned (@sha256:) — immutable, not a bare mutable tag" {
  run yq '.spec.template.spec.containers[0].image' "$D"
  [[ "$output" == *"@sha256:"* ]]
}
