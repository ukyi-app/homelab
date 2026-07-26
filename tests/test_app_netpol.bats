#!/usr/bin/env bats
# app-owned NetworkPolicy app-scoped 셀렉터 가드 (blast radius 차단). @test 이름은 영어(CJK 함정).
# CI-safe(yq만, 라이브/age/docker 불요) → run-bats.sh gate 도메인에 자동 수집.

@test "current repo passes (in-repo apps own no broad NetworkPolicy)" {
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh"
  echo "$output"
  [ "$status" -eq 0 ]
}

# 헬퍼: 임시 트리에 apps/<app>/deploy/prod/netpol.yaml(주어진 podSelector) 구성.
# 스크립트를 복사하지 않는다 — 실 스크립트를 `--root <픽스처>`로 부른다. 가드가 공유 워커를 자기
# 실제 위치 기준으로 찾기 때문에, 복사본은 워커를 못 찾는다(스캔 대상 트리와 도구 위치의 분리).
_seed() {
  local root="$1" app="$2" selector="$3"
  mkdir -p "$root/apps/$app/deploy/prod"
  cat > "$root/apps/$app/deploy/prod/netpol.yaml" <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: $app-egress, namespace: prod }
spec:
  podSelector: $selector
  policyTypes: [Egress]
YAML
  # 워커의 apps-manifests 스코프는 tracked 열거다 — 픽스처도 추적 파일이어야 한다.
  git -C "$root" init -q; git -C "$root" add -A
}

@test "guard fails on empty podSelector (selects all pods in shared ns)" {
  tmp="$(mktemp -d)"
  _seed "$tmp" foo '{}'
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "guard fails on name-only selector (chart name is shared, non-unique)" {
  tmp="$(mktemp -d)"
  _seed "$tmp" foo '{ matchLabels: { "app.kubernetes.io/name": app } }'
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "guard fails when instance label does not match the app directory" {
  tmp="$(mktemp -d)"
  _seed "$tmp" foo '{ matchLabels: { "app.kubernetes.io/instance": bar } }'
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "guard passes when instance label equals the app directory (unique app-scoped)" {
  tmp="$(mktemp -d)"
  _seed "$tmp" foo '{ matchLabels: { "app.kubernetes.io/instance": foo } }'
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}
