#!/usr/bin/env bats
# files kustomize render 가드 — grep-on-source가 못 잡는 조립 출력(namespace 주입·sealed 포함). @test 영어. ⚠️ 중간단언 [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # CI(required gate)에선 skip 금지 — 툴 부재면 fail-closed(dead-green 방지, homepage 패턴).
  if ! command -v kustomize >/dev/null || ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "FAIL: CI인데 kustomize/yq 부재 — gate setup-toolchain 회귀"; return 1; }
    skip "kustomize/yq 미설치(로컬만)"
  fi
  RENDERED="$BATS_TEST_TMPDIR/files-render.yaml"
  ( cd "$ROOT" && kustomize build platform/files/prod ) > "$RENDERED" 2>/dev/null
}
@test "files kustomize build succeeds and emits core kinds under namespace files" {
  [ -s "$RENDERED" ]
  for kind in PersistentVolumeClaim Deployment Service HTTPRoute NetworkPolicy SealedSecret; do
    run yq -e "select(.kind == \"$kind\") | .kind" "$RENDERED"; [ "$status" -eq 0 ]
  done
  run yq -e 'select(.kind == "Deployment") | .metadata.namespace' "$RENDERED"; [ "$output" = "files" ]
  # SealedSecret 2개(files-keys·ghcr-pull) 모두 files ns — grep -v '---'로 yq 다중문서 구분자 제거 후 sort -u.
  run bash -c "yq 'select(.kind==\"SealedSecret\") | .metadata.namespace' '$RENDERED' | grep -v '^---\$' | sort -u"
  [ "$output" = "files" ]
}
@test "two HTTPRoutes render (internal + public listeners)" {
  # yq 다중문서 select는 문서 사이에 '---'를 내므로 grep -v로 제거 후 카운트(homelab yq 함정).
  run bash -c "yq 'select(.kind==\"HTTPRoute\") | .metadata.name' '$RENDERED' | grep -v '^---\$' | grep -c ."
  [ "$output" -eq 2 ]
}
