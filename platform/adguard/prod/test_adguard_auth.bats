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
