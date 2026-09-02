#!/usr/bin/env bats
# verify-db-marker — per-DB freshness 마커(db-<name>-ready) 소비자(adversarial pass4).
# ensure-role-password Job이 방출한 마커가 (a) 존재하고 (b) 기록된 resourceVersion이 현재 owner/ro
# 비번 Secret의 resourceVersion과 일치(=fresh)함을 검증한다 — stale한 이전 검증/무관 신호로 온보딩이
# 통과되는 레이스를 차단. kubectl을 PATH 스텁으로 대체(라이브 무접근). ⚠️ @test 이름 영어.

# ⚠️ **피연산자 실재 증인 + 거부 문구 양성 대조.** `bun <없는 파일>`은 rc **1**이고 이 도구의
#    **거부**도 1이라 `-ne 0` 단독은 둘을 구별하지 못한다(ADR-0007 · 함정 「테스트 이름은 인터페이스가
#    아니다」). 실측(2026-09-02, 도구를 지운 격리 트리): 5건 중 「rejects a malformed db name」만 `ok`였다.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TOOL="$ROOT/tools/verify-db-marker.ts"
  [ -f "$TOOL" ]
  TMP="$(mktemp -d)"
  export VDM_MARKER_OWNER="100" VDM_MARKER_RO="100"   # 마커에 기록된 rv
  export VDM_SECRET_OWNER="100" VDM_SECRET_RO="100"   # 현재 비번 Secret rv
  export VDM_MARKER_PRESENT="1"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"get configmap"*"-ready"*)
    [ "$VDM_MARKER_PRESENT" = "1" ] || { echo "NotFound" >&2; exit 1; }
    printf '{"data":{"ownerSecretResourceVersion":"%s","roSecretResourceVersion":"%s","verifiedAt":"2026-06-29T00:00:00Z"}}' "$VDM_MARKER_OWNER" "$VDM_MARKER_RO" ;;
  *"get secret"*"-owner"*)
    printf '%s' "$VDM_SECRET_OWNER" ;;
  *"get secret"*"-ro"*)
    printf '%s' "$VDM_SECRET_RO" ;;
  *) : ;;
esac
exit 0
STUB
  chmod +x "$TMP/bin/kubectl"
}
teardown() { rm -rf "$TMP"; }
vdm() { PATH="$TMP/bin:$PATH" run bun "$TOOL" "$@"; }

@test "fresh marker (rv matches both secrets) passes" {
  vdm --name example-api
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"ok":true'
}

@test "stale owner rv (marker != current secret) fails closed" {
  export VDM_SECRET_OWNER="105" # secret 회전됨, 마커는 여전히 100
  vdm --name example-api
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "stale"
}

@test "stale ro rv fails closed" {
  export VDM_SECRET_RO="107"
  vdm --name example-api
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "stale"
}

@test "missing marker fails closed (DB not yet verified)" {
  export VDM_MARKER_PRESENT="0"
  vdm --name example-api
  [ "$status" -ne 0 ]
  # 오진단 방지(d6③ 이관에서 실측된 회귀 클래스): die 문구에 kubectl의 실제 실패 사유(stderr)가
  # 동봉된다 — 연결/인증 실패가 "마커 부재"로만 읽히면 운영자가 엉뚱한 곳(ensure-role-password)을 판다.
  echo "$output" | grep -q "kubectl:"
  echo "$output" | grep -q "NotFound"
}

@test "rejects a malformed db name before touching the cluster" {
  vdm --name "Bad_Name"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'db 이름 형식 불량'
}
