#!/usr/bin/env bats
# AdGuard UI 인증 배선 가드. AdGuard는 users:(bcrypt 해시)만 인증 수단이라(secret/env 네이티브 미지원)
# inject-auth init이 SealedSecret의 해시를 PVC config의 .users에 매 시작 주입한다(GitOps 강제).
# (@test 이름은 영어 — 디렉토리 단위 실행 시 한글이 인코딩 깨짐. 중간 단언은 [ ]/grep 단순 명령.)
# ⚠️ 부재 단언은 `[ "$status" -eq 1 ]`이다 — 피연산자가 전부 단일 파일이라 그것으로 닫힌다.
#    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③

D="$BATS_TEST_DIRNAME/deployment.yaml"
K="$BATS_TEST_DIRNAME/kustomization.yaml"
S="$BATS_TEST_DIRNAME/adguard-auth.sealed.yaml"

@test "inject-auth init injects users from the sealed bcrypt hash via yq" {
  run grep -q 'name: inject-auth' "$D"; [ "$status" -eq 0 ]
  run grep -q 'image: mikefarah/yq' "$D"; [ "$status" -eq 0 ]
  # .users를 yq strenv로 set — 평문 보간 없이 bcrypt $ 안전 처리
  run grep -q '.users = \[{"name": strenv(AGH_USER), "password": strenv(AGH_PW_HASH)}\]' "$D"; [ "$status" -eq 0 ]
  # 해시는 SealedSecret 백킹 Secret에서, username은 평문 env
  run grep -q 'key: PASSWORD_HASH' "$D"; [ "$status" -eq 0 ]
  run grep -q 'name: adguard-auth' "$D"; [ "$status" -eq 0 ]
  run grep -qE 'name: AGH_USER, value: ukkiee' "$D"; [ "$status" -eq 0 ]
}

@test "inject-auth init is restricted-compliant (setcap not needed unlike main container)" {
  # yq init은 NET_BIND_SERVICE/setcap이 불필요 → restricted 완전 충족(메인 컨테이너는 ape:true 필요).
  run grep -q 'readOnlyRootFilesystem: true' "$D"; [ "$status" -eq 0 ]
  run grep -q 'seccompProfile: { type: RuntimeDefault }' "$D"; [ "$status" -eq 0 ]
  # yq -i는 /tmp에 임시파일을 쓴다 — emptyDir로 readOnlyRootFilesystem과 양립
  run grep -q 'name: tmp' "$D"; [ "$status" -eq 0 ]
  run grep -qE 'name: tmp[[:space:]]*$|name: tmp,' "$D"; [ "$status" -eq 0 ]
}

@test "every init container that writes the PVC runs as 65532 (empty-PVC cold start)" {
  # ⚠️ 2026-08-14 NUC 콜드스타트 실측: seed-config에 securityContext가 없어 root로 돌았고,
  #    cp가 AdGuardHome.yaml을 `0644 root:root`로 만들자 다음 init인 inject-auth(65532)가
  #    `permission denied`로 죽어 파드가 Init:CrashLoopBackOff에 빠졌다.
  #    fsGroup은 구제책이 아니다 — **hostPath 백엔드 PV에는 적용되지 않는다**(실측: PVC 디렉토리가
  #    fsGroup 소유가 아니라 root:root 0777이었다). 디렉토리가 0777이라 생성은 되지만,
  #    root가 만든 파일은 65532가 열지 못한다.
  #    라이브 Mac에서는 원리적으로 안 보인다: 파일이 이미 있어 cp -n이 건너뛴다. **빈 PVC 전용 결함.**
  # PVC(data 볼륨)를 마운트하는 init 컨테이너 수 == runAsUser 65532를 가진 init 컨테이너 수.
  mounts="$(yq -e '[.spec.template.spec.initContainers[] | select([.volumeMounts[].name] | contains(["data"]))] | length' "$D")"
  as65532="$(yq -e '[.spec.template.spec.initContainers[] | select([.volumeMounts[].name] | contains(["data"])) | select(.securityContext.runAsUser == 65532)] | length' "$D")"
  [ -n "$mounts" ]
  # 양성 대조 — 대상 0을 "전부 통과"로 오독하지 않는다.
  # ⚠️ 중간 부정(`! cmd | cmd`)은 금지 — bats가 침묵 통과시킨다(check-bats-style이 잡는다).
  [ "$mounts" -ge 1 ]
  printf '%s' "$as65532" | grep -qxF -- "$mounts"
  # 그 uid는 메인 컨테이너의 uid와 같아야 한다(다르면 다시 소유권이 갈린다).
  main="$(yq -e '.spec.template.spec.containers[] | select(.name == "adguard") | .securityContext.runAsUser' "$D")"
  printf '%s' "$main" | grep -qxF -- '65532'
  # root로 도는 init이 하나도 없어야 한다.
  root="$(yq -e '[.spec.template.spec.initContainers[] | select(.securityContext.runAsNonRoot != true)] | length' "$D")"
  printf '%s' "$root" | grep -qxF -- '0'
}

@test "the adguard container has a DNS readiness probe (replicas_ready must mean 'DNS answers')" {
  # 프로브가 없으면 kubelet이 프로세스 기동만으로 Ready로 두고, LanDnsPathDown이 보는
  # replicas_ready가 'DNS가 응답한다'가 아니라 '프로세스가 살아 있다'가 된다(무성 클래스).
  probe="$(yq -e '.spec.template.spec.containers[] | select(.name == "adguard") | .readinessProbe.exec.command[0]' "$D")"
  printf '%s' "$probe" | grep -qxF -- 'nslookup'
  # 질의 대상은 rewrite로 로컬 응답되는 *.home 이름이어야 한다 — 업스트림에 의존하면 프로브가
  # AdGuard가 아니라 인터넷을 잰다(그러면 상류 장애가 LAN DNS 자기단절이 된다).
  host="$(yq -e '.spec.template.spec.containers[] | select(.name == "adguard") | .readinessProbe.exec.command[2]' "$D")"
  printf '%s' "$host" | grep -qF -- '.home.'
  # ⚠️ livenessProbe는 **의도적으로 없다** — replicas 1 + LoadBalancer라 kubelet 재시작이 곧 LAN DNS
  #    단절이고, cpu limit 200m 아래 블록리스트 갱신 스파이크와 겹치면 자기유발 루프가 된다.
  #    되돌리려면 deployment.yaml의 근거 주석부터 고쳐라(이 단언은 그 결정의 증인이다).
  run yq -e '.spec.template.spec.containers[] | select(.name == "adguard") | .livenessProbe' "$D"
  [ "$status" -eq 1 ]
}

@test "auth-sealed is a SealedSecret (no plaintext) named adguard-auth in edge" {
  run grep -q 'kind: SealedSecret' "$S"; [ "$status" -eq 0 ]
  run grep -q 'name: adguard-auth' "$S"; [ "$status" -eq 0 ]
  run grep -q 'namespace: edge' "$S"; [ "$status" -eq 0 ]
  run grep -q 'PASSWORD_HASH' "$S"; [ "$status" -eq 0 ]
  # 봉인본에는 평문 Secret 필드(stringData/data)가 없어야 한다 — encryptedData만.
  run grep -qE '^\s*stringData:|^\s*data:' "$S"; [ "$status" -eq 1 ]
  run grep -q 'encryptedData:' "$S"; [ "$status" -eq 0 ]
  # kustomization이 SealedSecret을 포함
  run grep -q 'adguard-auth.sealed.yaml' "$K"; [ "$status" -eq 0 ]
}

@test "api-creds is a SealedSecret named adguard-api-creds in edge (reconciler basic-auth password)" {
  # 메타갭 ① Task 6(W2-A): rewrite 리컨실러 basic auth용 평문 비밀번호(UI는 bcrypt·API는 평문, 같은 ADGUARD_PASSWORD).
  A="$BATS_TEST_DIRNAME/adguard-api-creds.sealed.yaml"
  run grep -q 'kind: SealedSecret' "$A"; [ "$status" -eq 0 ]
  run grep -q 'name: adguard-api-creds' "$A"; [ "$status" -eq 0 ]
  run grep -q 'namespace: edge' "$A"; [ "$status" -eq 0 ]
  run grep -q 'ADGUARD_PASSWORD' "$A"; [ "$status" -eq 0 ]
  # 봉인본에는 평문 필드 없음 — encryptedData만.
  run grep -qE '^\s*stringData:|^\s*data:' "$A"; [ "$status" -eq 1 ]
  run grep -q 'encryptedData:' "$A"; [ "$status" -eq 0 ]
  run grep -q 'adguard-api-creds.sealed.yaml' "$K"; [ "$status" -eq 0 ]
}

@test "reconciler wires username plaintext (ukkiee) + password via adguard-api-creds envFrom" {
  # username은 비밀 아님 → env 평문(deployment inject-auth AGH_USER 동일 규약), password만 봉인본 envFrom.
  R="$BATS_TEST_DIRNAME/rewrite-reconciler.yaml"
  run grep -qE 'name: ADGUARD_USER, value: ukkiee' "$R"; [ "$status" -eq 0 ]
  run grep -q 'secretRef: { name: adguard-api-creds }' "$R"; [ "$status" -eq 0 ]
}
