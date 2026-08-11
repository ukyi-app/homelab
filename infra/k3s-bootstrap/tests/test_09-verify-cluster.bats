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

  # 노드 명령 시임(K3S_RUN) 스텁 — 베어메탈에서는 `sudo`가 들어가는 자리다.
  # OrbStack 시절의 `orb -m k3s -u root <cmd>` 간접이 사라졌으므로 스텁도 그 모양을 버린다.
  echo "$K3S_NODE_IP" > "$STUBDIR/nodeip.txt"
  printf 'X509v3 Subject Alternative Name:\n    DNS:localhost, DNS:homelab, IP Address:127.0.0.1' > "$STUBDIR/certsans.txt"
  for s in $K3S_TLS_SANS; do printf ', SAN:%s' "$s" >> "$STUBDIR/certsans.txt"; done
  cat >"$STUBDIR/noderun" <<'EOF'
#!/usr/bin/env bash
# `$K3S_RUN <cmd...>` 대역. 알려진 하위 명령만 흉내낸다.
case "$*" in
  *"secrets-encrypt status"*)
    if [ "$(cat "$STUBDIR/encryption.txt")" = "true" ]; then
      echo "Encryption Status: Enabled"; else echo "Encryption Status: Disabled"; fi ;;
  *"openssl"*|*"x509"*) cat "$STUBDIR/certsans.txt" ;;
esac
exit 0
EOF
  chmod +x "$STUBDIR/noderun"
  export K3S_RUN="$STUBDIR/noderun"

  cat >"$STUBDIR/kubectl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"nodeInfo.kubeletVersion"*) cat "$STUBDIR/kubeletversion.txt" ;;
  *"InternalIP"*)        cat "$STUBDIR/nodeip.txt" ;;
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

# ── 베어메탈 신규 검사 ───────────────────────────────────────────────────────────────────────
@test "fails when the live node InternalIP drifts from the versions.env pin" {
  # netpol의 노드 서브넷 allow 6곳이 이 값의 /24를 전제한다 — 표류하면 워크로드가 apiserver를 잃는다.
  echo "192.168.9.9" > "$STUBDIR/nodeip.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'InternalIP drift'
}

@test "fails when a pinned SAN is missing from the LIVE serving cert (not just the flag string)" {
  # ⚠️ 이 @test가 [8]의 존재 이유다. 스크립트가 방출하는 플래그를 grep하면 "스크립트가 그렇게 낼
  #    것이다"만 증명된다. --tls-san은 설치 시점에만 정해지므로 **라이브 cert**를 봐야 한다.
  printf 'X509v3 Subject Alternative Name:\n    DNS:localhost, IP Address:127.0.0.1' > "$STUBDIR/certsans.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'serving cert에 없는 SAN'
}

@test "fails when the serving cert cannot be read at all (empty SAN output is not a pass)" {
  : > "$STUBDIR/certsans.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'SAN을 읽지 못했다'
}

@test "an emptied SAN list trips THIS script's own floor, not just the installer's" {
  # 루프가 0회 도는 것은 통과가 아니다(scan-floor와 같은 규약).
  # ⚠️ `K3S_INSTALL_SCRIPT`를 스텁으로 바꾼다. 안 그러면 [4]가 부르는 진짜 k3s-install.sh의
  #    **자기 바닥값**이 먼저 죽어서, verify-cluster의 바닥값을 지워도 이 @test가 통과한다 —
  #    역방향 뮤테이션에서 실제로 그랬다(죽은 규칙으로 보였다). 스텁이 그 그늘을 걷어낸다.
  cp -R "$BOOTSTRAP_DIR" "$STUBDIR/bs"
  sed -i.bak 's/^export K3S_TLS_SANS=.*/export K3S_TLS_SANS=""/' "$STUBDIR/bs/versions.env"
  STUB="$STUBDIR/ok-install.sh"
  printf '#!/usr/bin/env bash\necho "server --secrets-encryption"\n' > "$STUB"; chmod +x "$STUB"
  K3S_INSTALL_SCRIPT="$STUB" run "$STUBDIR/bs/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'K3S_TLS_SANS'
}
