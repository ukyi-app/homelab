#!/usr/bin/env bats
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"; PATH="$STUBDIR:$PATH"; export PATH STUBDIR
  export KUBECONFIG_PATH="$STUBDIR/kubeconfig"; : > "$KUBECONFIG_PATH"
  # 건강한 기본값; 개별 테스트는 stub이 읽는 env 파일로 덮어쓴다.
  : > "$STUBDIR/pods.txt"          # kube-system pod 이름, 한 줄에 하나
  echo "svclb-traefik-abc"      >> "$STUBDIR/pods.txt"   # servicelb LB pod (traefik 컨트롤러가 아님)
  echo "coredns-xyz"            >> "$STUBDIR/pods.txt"
  echo "true"  > "$STUBDIR/encryption.txt"               # secrets-encrypt 활성화
  echo "Ready" > "$STUBDIR/nodestatus.txt"
  printf 'standard\nbulk-ssd\n' > "$STUBDIR/sc.txt"
  source "$BOOTSTRAP_DIR/versions.env"; echo "$K3S_VERSION" > "$STUBDIR/kubeletversion.txt"  # 건강한 기본값 = 핀 버전

  cat >"$STUBDIR/orb" <<'EOF'
#!/usr/bin/env bash
# `orb -m k3s -u root k3s secrets-encrypt status` 를 에뮬레이트
shift 4 2>/dev/null || true
if printf '%s ' "$@" | grep -q 'secrets-encrypt status'; then
  if [ "$(cat "$STUBDIR/encryption.txt")" = "true" ]; then
    echo "Encryption Status: Enabled"; else echo "Encryption Status: Disabled"; fi
fi
exit 0
EOF
  chmod +x "$STUBDIR/orb"

  cat >"$STUBDIR/kubectl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"nodeInfo.kubeletVersion"*) cat "$STUBDIR/kubeletversion.txt" ;;
  *"get nodes"*)         cat "$STUBDIR/nodestatus.txt" ;;
  *"get pods"*)          cat "$STUBDIR/pods.txt" ;;
  *"get sc"*|*"get storageclass"*) cat "$STUBDIR/sc.txt" ;;
esac
exit 0
EOF
  chmod +x "$STUBDIR/kubectl"
}
teardown() { rm -rf "$STUBDIR"; }

@test "passes on a healthy cluster fixture" {
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -eq 0 ]
}

@test "the servicelb LB pod (svclb-traefik-*) is NOT mistaken for a traefik controller" {
  # 정밀한 '^traefik-' 매칭의 회귀 가드: 건강한 픽스처에 이미 svclb-traefik-abc가
  # 들어 있으므로, 통과하는 실행이 곧 오탐 없음의 증명이다.
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -eq 0 ]
}

@test "fails when a traefik controller pod is present (must be disabled)" {
  echo "traefik-7d9-runaway" >> "$STUBDIR/pods.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"traefik"* ]]
}

@test "fails when servicelb is disabled in the k3s install flags (must be kept)" {
  # 스크립트는 플래그 계약을 단언한다 (svclb pod는 M3에서 온디맨드). servicelb를
  # 비활성화하는 잘못된 install 스크립트는 반드시 가드에 걸려야 한다.
  BAD="$STUBDIR/bad-k3s-install.sh"
  cat >"$BAD" <<'EOF'
#!/usr/bin/env bash
echo "server --disable=traefik,servicelb,local-storage,metrics-server --secrets-encryption"
EOF
  chmod +x "$BAD"
  K3S_INSTALL_SCRIPT="$BAD" run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"servicelb"* ]]
}

@test "fails when secrets-encryption is disabled" {
  echo "false" > "$STUBDIR/encryption.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"encryption"* ]]
}

@test "fails when metrics-server pod is present (must be disabled)" {
  echo "metrics-server-zzz" >> "$STUBDIR/pods.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
}

@test "fails when live k3s version drifts from versions.env K3S_VERSION" {
  echo "v1.99.9+k3s1" > "$STUBDIR/kubeletversion.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"version"* ]]
}
