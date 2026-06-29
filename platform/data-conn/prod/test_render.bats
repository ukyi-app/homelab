#!/usr/bin/env bats
# data-conn 컴포넌트 렌더 검증 — 빈 resources여도 kustomize build가 성공해야 하고
# (appset 발견 시점에 DB가 0개일 수 있음), namespace: prod 변환이 강제되는지 확인한다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TMP="$(mktemp -d)"
}

teardown() { rm -rf "$TMP"; }

@test "data-conn builds cleanly even with zero resources" {
  run kustomize build "$ROOT/platform/data-conn/prod"
  [ "$status" -eq 0 ]
}

@test "data-conn kustomization pins namespace prod" {
  [ "$(yq '.namespace' "$ROOT/platform/data-conn/prod/kustomization.yaml")" = "prod" ]
}

@test "namespace transformer forces prod on every added resource" {
  # 실제 kustomization을 복사해 더미 리소스를 추가 — 변환기가 namespace를 prod로 덮는지 증명
  cp "$ROOT/platform/data-conn/prod/kustomization.yaml" "$TMP/kustomization.yaml"
  # 상속된 실제 conn 리소스 참조는 비운다($TMP로 파일을 복사하지 않으므로). 이 테스트는 namespace
  # 변환기만 검증하며, data-conn에 실제 DB conn이 생기면(첫 온보딩 앱) 그대로 두면 미존재 파일로 빌드 실패.
  (cd "$TMP" && yq -i '.resources = []' kustomization.yaml)
  cat > "$TMP/dummy.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: dummy
  namespace: default
EOF
  (cd "$TMP" && kustomize edit add resource dummy.yaml)
  run kustomize build "$TMP"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "namespace: prod"
  ! echo "$output" | grep -q "namespace: default"
}
