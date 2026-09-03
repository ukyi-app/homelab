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
  echo "$K3S_NODE_NAME" > "$STUBDIR/nodename.txt"
  # ⚠️ **실제 openssl 출력 형식이어야 한다.** 예전 픽스처는 `SAN:<값>`이라는 존재하지 않는 접두를
  #    썼는데, 검사가 부분일치(grep -F)라 그래도 통과했다. 정확일치로 바꾸면 그 가짜 형식이 곧바로
  #    드러난다 — 픽스처가 실물과 다르면 게이트는 아무것도 증명하지 못한다.
  #    라이브 실측: `DNS:kubernetes, …, DNS:nuc-15-pro, DNS:nuc-15-pro.tailcf1ac6.ts.net,
  #                  IP Address:192.168.117.15, IP Address:100.109.208.81, …`
  printf 'X509v3 Subject Alternative Name:\n    DNS:localhost, DNS:homelab, IP Address:127.0.0.1' > "$STUBDIR/certsans.txt"
  for s in $K3S_TLS_SANS; do
    case "$s" in
      [0-9]*) printf ', IP Address:%s' "$s" >> "$STUBDIR/certsans.txt" ;;
      *)      printf ', DNS:%s' "$s" >> "$STUBDIR/certsans.txt" ;;
    esac
  done
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

  # 라이브 설치 argv — [4]가 보는 권위다. 건강한 기본값은 실제 노드에서 뜬 것과 같은 모양으로 둔다
  # (servicelb 없음 · --secrets-encryption 있음). 개별 @test가 이 파일을 덮어쓴다.
  printf '["server","--node-ip","%s","--node-name","%s","--disable","traefik,local-storage,metrics-server","--secrets-encryption"]' \
    "$K3S_NODE_IP" "$K3S_NODE_NAME" > "$STUBDIR/nodeargs.txt"

  cat >"$STUBDIR/kubectl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"nodeInfo.kubeletVersion"*) cat "$STUBDIR/kubeletversion.txt" ;;
  *"node-args"*)         cat "$STUBDIR/nodeargs.txt" ;;
  *"InternalIP"*)        cat "$STUBDIR/nodeip.txt" ;;
  *"metadata.name"*)     cat "$STUBDIR/nodename.txt" ;;
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

@test "fails when the node is not Ready" {
  # 🔴 [1]·[2]의 판정 술어 3개를 `true`로 바꿔도 17레인이 전건 초록이었다 — setup이 건강한
  #    nodestatus.txt/sc.txt를 깔 뿐 그 둘을 **망가뜨리는 레인이 0**이었기 때문이다.
  #    거부 문구를 소스 리터럴로 잡으면 그것이 곧 피연산자 실재 증인이다(rc 127은 그 문구를 못 낸다).
  echo "NotReady" > "$STUBDIR/nodestatus.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'node is not Ready'
}

@test "fails when the bulk-ssd StorageClass is missing (partial apply is not a pass)" {
  printf 'standard\n' > "$STUBDIR/sc.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- "StorageClass 'bulk-ssd' missing"
}

@test "fails when the standard StorageClass is missing (each SC carries its own witness)" {
  # 두 SC를 한 레인으로 묶으면 :33 단독 뮤테이션이 빠져나간다(실측) — 레인을 나눠 적는다.
  printf 'bulk-ssd\n' > "$STUBDIR/sc.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- "StorageClass 'standard' missing"
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

@test "fails when servicelb is disabled in the LIVE k3s flags (must be kept)" {
  # 스크립트는 플래그 계약을 단언한다 (svclb pod는 M3에서 온디맨드).
  # ⚠️ 예전엔 레포의 k3s-install.sh를 스텁으로 갈아끼워 검사했다 — 그건 "스크립트가 무엇을 낼
  #    것인가"만 증명하고 **라이브가 그 플래그로 설치됐는가**는 전혀 증명하지 않았다. 지금은
  #    k3s가 설치 시 남기는 node-args 어노테이션이 권위다(같은 파일 [8]·[9]와 같은 기조).
  printf '["server","--disable","traefik,servicelb,local-storage,metrics-server","--secrets-encryption"]' > "$STUBDIR/nodeargs.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"servicelb"* ]]
}

@test "fails when the live node-args annotation is unreadable (empty is not a pass)" {
  # 어노테이션을 못 읽으면 servicelb 부재를 '확인'한 것이 아니라 아무것도 안 본 것이다.
  : > "$STUBDIR/nodeargs.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'node-args'
}

@test "fails when the live flags lack --secrets-encryption" {
  printf '["server","--disable","traefik,local-storage,metrics-server"]' > "$STUBDIR/nodeargs.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'secrets-encryption'
}

@test "fails when secrets-encryption is disabled" {
  echo "false" > "$STUBDIR/encryption.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"encryption"* ]]
}

@test "fails when metrics-server pod is present (must be disabled)" {
  # ⚠️ `-ne 0`만으로는 「검사가 metrics-server를 잡았다」와 「verify-cluster.sh가 없어 못 돌았다」가
  #    겹친다(실측: 스크립트 삭제 시 17레인 중 이 레인만 그대로 초록이었다). 거부 문구로 가른다.
  [ -f "$BOOTSTRAP_DIR/verify-cluster.sh" ]
  echo "metrics-server-zzz" >> "$STUBDIR/pods.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'metrics-server pod present'
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

@test "fails when the live node name drifts from the versions.env pin" {
  # ⚠️ hostPath PV의 nodeAffinity가 이 값을 담는다. 사후 변경은 노드 재등록 + PV 재작성이라
  #    표류를 늦게 발견할수록 비싸다 — 그래서 [8]과 같이 **라이브 오브젝트**를 본다.
  echo "homelab" > "$STUBDIR/nodename.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'node name drift'
}

@test "fails when the live node name cannot be read at all (empty is not a pass)" {
  : > "$STUBDIR/nodename.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '라이브 노드명을 읽지 못했다'
}

@test "fails when a pinned SAN is missing from the LIVE serving cert (not just the flag string)" {
  # ⚠️ 이 @test가 [8]의 존재 이유다. 스크립트가 방출하는 플래그를 grep하면 "스크립트가 그렇게 낼
  #    것이다"만 증명된다. --tls-san은 설치 시점에만 정해지므로 **라이브 cert**를 봐야 한다.
  # ⚠️ 픽스처는 k3s가 기본으로 넣는 SAN들로 채운다 — 핀만 빠진 cert여야 이 @test가 "핀 부재"를
  #    보는 것이지, 토큰이 몇 개 없으면 형식 바닥값에 먼저 걸려 **다른 이유로 red**가 된다
  #    (그러면 status는 여전히 비-0이라 단언이 통과해 버려, 무엇을 증명했는지 알 수 없어진다).
  printf 'X509v3 Subject Alternative Name:\n    DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:localhost, DNS:k3s, IP Address:127.0.0.1, IP Address:10.43.0.1' > "$STUBDIR/certsans.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'serving cert에 없는 SAN'
}

@test "a mangled SAN format is reported as a format problem, not as missing pins" {
  # 토큰화가 깨지면(openssl 출력 형식 변화 등) 핀 전건이 missing으로 보인다 — 그 오진을 막는 바닥값.
  printf 'X509v3 Subject Alternative Name:\n    DNS:localhost' > "$STUBDIR/certsans.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '토큰'
}

@test "fails when the serving cert cannot be read at all (empty SAN output is not a pass)" {
  : > "$STUBDIR/certsans.txt"
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'SAN을 읽지 못했다'
}

@test "an emptied SAN list trips THIS script's own floor, not just the installer's" {
  # 루프가 0회 도는 것은 통과가 아니다(scan-floor와 같은 규약).
  # ⚠️ 예전엔 여기서 `K3S_INSTALL_SCRIPT`를 스텁으로 갈아끼워야 했다 — [4]가 진짜 k3s-install.sh를
  #    실행했고 그 **자기 바닥값**이 먼저 죽어서, verify-cluster의 바닥값을 지워도 이 @test가
  #    통과했기 때문이다(역방향 뮤테이션에서 죽은 규칙으로 보였다). [4]가 라이브 어노테이션을
  #    보게 된 지금은 그 그늘 자체가 없어서 스텁이 필요 없다.
  cp -R "$BOOTSTRAP_DIR" "$STUBDIR/bs"
  sed -i.bak 's/^export K3S_TLS_SANS=.*/export K3S_TLS_SANS=""/' "$STUBDIR/bs/versions.env"
  run "$STUBDIR/bs/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'K3S_TLS_SANS'
}

@test "a SAN that is only a prefix of a longer one does not count as present" {
  # ⚠️ 라이브 SAN은 `DNS:nuc-15-pro, DNS:nuc-15-pro.tailcf1ac6.ts.net` 형태다. 부분일치로 보면
  #    짧은 이름이 cert에서 **빠져도** 긴 이름에 매치돼 초록이 된다 — 정확일치가 그것을 막는다.
  printf 'X509v3 Subject Alternative Name:\n    DNS:localhost, IP Address:127.0.0.1' > "$STUBDIR/certsans.txt"
  for s in $K3S_TLS_SANS; do
    case "$s" in
      nuc-15-pro) : ;;                                  # 짧은 이름만 뺀다(FQDN은 남긴다)
      [0-9]*) printf ', IP Address:%s' "$s" >> "$STUBDIR/certsans.txt" ;;
      *)      printf ', DNS:%s' "$s" >> "$STUBDIR/certsans.txt" ;;
    esac
  done
  run "$BOOTSTRAP_DIR/verify-cluster.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'nuc-15-pro'
}
