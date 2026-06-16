#!/usr/bin/env bats
# AdGuard UI 인증 배선 가드. AdGuard는 users:(bcrypt 해시)만 인증 수단이라(secret/env 네이티브 미지원)
# inject-auth init이 SealedSecret의 해시를 PVC config의 .users에 매 시작 주입한다(GitOps 강제).
# (@test 이름은 영어 — 디렉토리 단위 실행 시 한글이 인코딩 깨짐. 중간 단언은 [ ]/grep 단순 명령.)

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

@test "auth-sealed is a SealedSecret (no plaintext) named adguard-auth in edge" {
  run grep -q 'kind: SealedSecret' "$S"; [ "$status" -eq 0 ]
  run grep -q 'name: adguard-auth' "$S"; [ "$status" -eq 0 ]
  run grep -q 'namespace: edge' "$S"; [ "$status" -eq 0 ]
  run grep -q 'PASSWORD_HASH' "$S"; [ "$status" -eq 0 ]
  # 봉인본에는 평문 Secret 필드(stringData/data)가 없어야 한다 — encryptedData만.
  run grep -qE '^\s*stringData:|^\s*data:' "$S"; [ "$status" -ne 0 ]
  run grep -q 'encryptedData:' "$S"; [ "$status" -eq 0 ]
  # kustomization이 SealedSecret을 포함
  run grep -q 'adguard-auth.sealed.yaml' "$K"; [ "$status" -eq 0 ]
}
