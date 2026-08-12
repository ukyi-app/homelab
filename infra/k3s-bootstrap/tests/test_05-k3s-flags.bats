#!/usr/bin/env bats
load test_helper

# k3s-install.sh는 VM을 건드리지 않고 INSTALL_K3S_EXEC를 출력하는 `print_exec`
# 모드를 제공하므로, 플래그 계약을 오프라인에서 단위 테스트할 수 있다.
setup() { EXEC="$(K3S_PRINT_EXEC=1 "$BOOTSTRAP_DIR/k3s-install.sh")"; }

@test "disables traefik, local-storage, metrics-server" {
  [[ "$EXEC" == *"--disable=traefik,local-storage,metrics-server"* ]]
}
@test "disables the helm-controller" {
  [[ "$EXEC" == *"--disable-helm-controller"* ]]
}
@test "KEEPS servicelb (must NOT be in any --disable list)" {
  [[ "$EXEC" != *"servicelb"* ]]
}
@test "flannel backend is vxlan" {
  [[ "$EXEC" == *"--flannel-backend=vxlan"* ]]
}
# kube-reserved/system-reserved/eviction-hard/image-gc-* 는 KUBELET 플래그라서
# 반드시 --kubelet-arg= 로 전달해야 한다 (k3s server는 단독 플래그로 주면 거부한다).
@test "kube-reserved and system-reserved go through --kubelet-arg" {
  printf '%s' "$EXEC" | grep -qF -- "--kubelet-arg=kube-reserved=cpu=250m,memory=512Mi"
  [[ "$EXEC" == *"--kubelet-arg=system-reserved=cpu=250m,memory=512Mi"* ]]
}
@test "eviction-hard set for memory and nodefs via --kubelet-arg" {
  [[ "$EXEC" == *"--kubelet-arg=eviction-hard=memory.available<250Mi,nodefs.available<10%"* ]]
}
@test "image GC thresholds are 80/70 via --kubelet-arg" {
  printf '%s' "$EXEC" | grep -qF -- "--kubelet-arg=image-gc-high-threshold=80"
  [[ "$EXEC" == *"--kubelet-arg=image-gc-low-threshold=70"* ]]
}
# kubelet 플래그가 k3s server 단독 플래그로 나타나면 안 된다 (라이브 bringup 때의 버그)
@test "kubelet flags are NOT passed as bare k3s server flags" {
  case "$EXEC" in *"--kube-reserved="*) false ;; *) true ;; esac
  case "$EXEC" in *"--system-reserved="*) false ;; *) true ;; esac
  [[ "$EXEC" != *"--eviction-hard="* ]]
}
@test "secrets encryption enabled and kubeconfig mode 0600 (private admin kubeconfig)" {
  printf '%s' "$EXEC" | grep -qF -- "--secrets-encryption"
  [[ "$EXEC" == *"--write-kubeconfig-mode=0600"* ]]
}
@test "datastore stays default sqlite/kine (no --cluster-init / etcd)" {
  case "$EXEC" in *"--cluster-init"*) false ;; *) true ;; esac
  [[ "$EXEC" != *"etcd"* ]]
}

@test "does NOT pass --default-local-storage-path (built-in local-storage provisioner is disabled → flag is a no-op)" {
  [[ "$EXEC" != *"--default-local-storage-path"* ]]
}

# ── 베어메탈 신규 플래그 ─────────────────────────────────────────────────────────────────────
@test "node-ip is pinned from versions.env (tailscale0 must not win the auto-detect)" {
  source "$BOOTSTRAP_DIR/versions.env"
  printf '%s' "$EXEC" | grep -qF -- "--node-ip=${K3S_NODE_IP}"
}

@test "node-name is pinned from versions.env (D-h: the linux hostname 'homelab' means three other things)" {
  # ⚠️ 설치 시점에만 정할 수 있고, 사후 변경은 노드 재등록이라 hostPath PV가 깨진다.
  source "$BOOTSTRAP_DIR/versions.env"
  [ -n "$K3S_NODE_NAME" ]
  printf '%s' "$EXEC" | grep -qF -- "--node-name=${K3S_NODE_NAME}"
}

@test "refuses to install when K3S_NODE_NAME is empty (silent fallback to the hostname is the bug)" {
  cp -R "$BOOTSTRAP_DIR" "$BATS_TEST_TMPDIR/bs2"
  sed -i.bak 's/^export K3S_NODE_NAME=.*/export K3S_NODE_NAME=""/' "$BATS_TEST_TMPDIR/bs2/versions.env"
  K3S_PRINT_EXEC=1 run "$BATS_TEST_TMPDIR/bs2/k3s-install.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'K3S_NODE_NAME 미설정'
}

@test "every SAN in versions.env reaches the flag string, and the list cannot silently empty" {
  # ⚠️ `for san in $LIST; do grep; done`만 쓰면 LIST가 비었을 때 루프가 0회 돌고 종료 0이라
  #    **vacuous green**이다. `--tls-san`은 설치 후 교정이 serving cert 삭제를 요구하는 불변식이라
  #    그 침묵이 특히 비싸다 — 카운터 + 바닥값을 같은 @test 안에 둔다(scan-floor와 같은 규약).
  source "$BOOTSTRAP_DIR/versions.env"
  n=0
  for san in $K3S_TLS_SANS; do
    printf '%s' "$EXEC" | grep -qF -- "--tls-san=$san"
    n=$((n + 1))
  done
  [ "$n" -ge 3 ]
}

@test "flannel-iface is NOT pinned (node-ip already selects the interface; two pins can diverge)" {
  case "$EXEC" in *"--flannel-iface"*) false ;; *) true ;; esac
}

# ── 실행 경로 — 이식 전 커버리지 0이던 구간 ──────────────────────────────────────────────────
# ⚠️ 아래 @test들이 이 파일에 있는 이유: `K3S_PRINT_EXEC=1`은 :39 이전에 조기 종료하므로
#    설치·폴링·kubeconfig 회수는 **한 줄도 실행된 적이 없었다**. 시임(K3S_RUN·K3S_INSTALLER_URL·
#    K3S_READY_*)이 그 구간을 오프라인에서 실행 가능하게 만든다.

# argv 기록기 + 가짜 인스톨러/​kubeconfig를 갖춘 샌드박스를 만든다.
_sandbox() {
  SB="$BATS_TEST_TMPDIR/sb"; mkdir -p "$SB/bin"
  cat > "$SB/bin/rec" <<'REC'
#!/usr/bin/env bash
# 권한 상승 시임 대역. argv를 기록하고, 알려진 하위 명령만 흉내낸다.
printf '%s\n' "$*" >> "$REC_LOG"
case "$1 $2" in
  "env INSTALL_K3S_VERSION="*) exec cat > /dev/null ;;  # stdin(인스톨러 본문) 소비
esac
case "$*" in
  "k3s kubectl get --raw=/readyz") [ -f "$SB/ready" ] || exit 1; exit 0 ;;
  "cat /etc/rancher/k3s/k3s.yaml") [ -f "$SB/kubeconfig.src" ] || exit 1; cat "$SB/kubeconfig.src" ;;
  *) : ;;
esac
REC
  chmod +x "$SB/bin/rec"
  printf '#!/bin/sh\necho fake-installer\n' > "$SB/installer.sh"
  # ⚠️ **k3s가 실제로 내는 형태여야 한다.** 회수 직후 kubeconfig-identity.sh가 이름 6필드를 각인하는데
  #    (context·cluster·user 전부 `default`), 픽스처에 그 필드가 없으면 각인기가 "형태가 예상과
  #    다르다"로 정지한다 — 그건 스크립트의 결함이 아니라 픽스처가 실물과 다른 것이다.
  #    라이브 실측 형태 그대로 둔다(주석/데이터 줄만 뺐다).
  printf '%s\n' \
    'apiVersion: v1' \
    'clusters:' \
    '- cluster:' \
    '    server: https://127.0.0.1:6443' \
    '  name: default' \
    'contexts:' \
    '- context:' \
    '    cluster: default' \
    '    user: default' \
    '  name: default' \
    'current-context: default' \
    'kind: Config' \
    'users:' \
    '- name: default' > "$SB/kubeconfig.src"
  export REC_LOG="$SB/argv.log" SB
  : > "$REC_LOG"
}
_run_install() {
  REC_LOG="$REC_LOG" SB="$SB" \
  K3S_RUN="$SB/bin/rec" \
  K3S_INSTALLER_URL="file://$SB/installer.sh" \
  K3S_READY_TRIES=2 K3S_READY_SLEEP=0 \
  KUBECONFIG_PATH="$SB/kubeconfig.out" \
  "$@" "$BOOTSTRAP_DIR/k3s-install.sh"
}

@test "install path: pins K3S_VERSION and passes the exact flag contract to the installer" {
  _sandbox; touch "$SB/ready"
  run _run_install env
  [ "$status" -eq 0 ]
  source "$BOOTSTRAP_DIR/versions.env"
  printf '%s' "$(cat "$REC_LOG")" | grep -qF -- "INSTALL_K3S_VERSION=${K3S_VERSION}"
  printf '%s' "$(cat "$REC_LOG")" | grep -qF -- "--secrets-encryption"
  printf '%s' "$(cat "$REC_LOG")" | grep -qF -- "--node-ip=${K3S_NODE_IP}"
}

@test "install path: stamps the cluster identity into the retrieved kubeconfig" {
  # D-i: 회수한 kubeconfig는 k3s 기본 이름(`default`)으로 남으면 안 된다. 라이브 Mac의 kubeconfig와
  # 경로·포트·노드명이 전부 같아서, 이 이름이 두 클러스터를 가르는 첫 텍스트 단서이기 때문이다.
  # ⚠️ 이 @test가 없으면 위임 호출을 통째로 지워도 나머지 install-path @test가 전부 통과한다.
  _sandbox; touch "$SB/ready"
  run _run_install env
  [ "$status" -eq 0 ]
  source "$BOOTSTRAP_DIR/versions.env"
  grep -qx "current-context: ${K3S_KUBECONFIG_NAME}" "$SB/kubeconfig.out"
  run grep -cE '^(  name|- name|    cluster|    user|current-context): default$' "$SB/kubeconfig.out"
  [ "$output" = "0" ]
}

@test "install path: writes the kubeconfig 0600 and does not leave a temp file" {
  _sandbox; touch "$SB/ready"
  run _run_install env
  [ "$status" -eq 0 ]
  [ -s "$SB/kubeconfig.out" ]
  # ⚠️ `stat -f '%Lp'`(BSD/macOS)도 `stat -c '%a'`(GNU)도 쓰지 않는다 — 둘은 서로의 플랫폼에서
  #    **다른 뜻이거나 에러**다. 실측: 로컬 macOS에서 전 스위트가 green이었는데 CI(ubuntu-24.04-arm)에서
  #    이 @test만 red였다(`stat -f`가 GNU에선 "파일시스템 상태"다). 이전이 끝나면 실행 환경이
  #    영구히 Linux가 되므로 이 클래스는 **한 번 밟으면 계속 밟는다**. `find -perm`은 POSIX라 양쪽 동일.
  run bash -c "find '$SB/kubeconfig.out' -perm 600 | grep -c ."
  printf '%s' "$output" | grep -qx '1'
  run bash -c "ls '$SB'/kubeconfig.out.tmp.* 2>/dev/null | grep -c ."
  printf '%s' "$output" | grep -qx '0'
}

@test "install path: a never-ready API aborts loudly instead of writing a kubeconfig" {
  _sandbox   # ready 파일 없음 → readyz 폴링이 계속 실패
  run _run_install env
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'k3s API가 준비되지 않았다'
  run bash -c "test -e '$SB/kubeconfig.out'"
  [ "$status" -ne 0 ]
}

@test "install path: a failed kubeconfig retrieval leaves NO empty file behind" {
  # ⚠️ 원본은 `orb ... cat ... > \$KUBECONFIG_PATH`였다 — 리다이렉트가 먼저 열려 회수가 실패해도
  #    **빈 kubeconfig**가 남는다. "존재하지만 쓸 수 없는" 상태가 가장 나쁘다.
  _sandbox; touch "$SB/ready"; rm -f "$SB/kubeconfig.src"
  run _run_install env
  [ "$status" -ne 0 ]
  run bash -c "test -e '$SB/kubeconfig.out'"
  [ "$status" -ne 0 ]
}

@test "install path: K3S_KUBECONFIG_SERVER rewrites the server URL (remote use needs a SAN name)" {
  _sandbox; touch "$SB/ready"
  run _run_install env K3S_KUBECONFIG_SERVER=https://nuc-15-pro.tailcf1ac6.ts.net:6443
  [ "$status" -eq 0 ]
  run grep -c 'server: https://nuc-15-pro.tailcf1ac6.ts.net:6443' "$SB/kubeconfig.out"
  printf '%s' "$output" | grep -qx '1'
  run grep -c '127.0.0.1' "$SB/kubeconfig.out"
  printf '%s' "$output" | grep -qx '0'
}

@test "an empty SAN list aborts instead of installing a cert that cannot be fixed afterwards" {
  # ⚠️ env로 K3S_TLS_SANS를 비울 수는 없다 — 스크립트가 versions.env를 **source**해서 덮어쓴다
  #    (versions.env가 SSOT라는 설계 그대로다). 그래서 **레포 상태 자체**를 변형해 검사한다:
  #    "versions.env에 목록이 비어 있으면 설치를 시작조차 하지 않는가".
  _sandbox; touch "$SB/ready"
  cp -R "$BOOTSTRAP_DIR" "$SB/bs"
  sed -i.bak 's/^export K3S_TLS_SANS=.*/export K3S_TLS_SANS=""/' "$SB/bs/versions.env"
  run env REC_LOG="$REC_LOG" SB="$SB" K3S_RUN="$SB/bin/rec" \
      K3S_INSTALLER_URL="file://$SB/installer.sh" K3S_READY_TRIES=2 K3S_READY_SLEEP=0 \
      KUBECONFIG_PATH="$SB/kubeconfig.out" "$SB/bs/k3s-install.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'K3S_TLS_SANS'
  run bash -c "grep -c . '$REC_LOG' || true"
  printf '%s' "$output" | grep -qx '0'   # 설치가 아예 시작되지 않았다
}

@test "an empty node IP aborts (netpol node-subnet allows depend on this value)" {
  _sandbox; touch "$SB/ready"
  cp -R "$BOOTSTRAP_DIR" "$SB/bs"
  sed -i.bak 's/^export K3S_NODE_IP=.*/export K3S_NODE_IP=""/' "$SB/bs/versions.env"
  run env REC_LOG="$REC_LOG" SB="$SB" K3S_RUN="$SB/bin/rec" \
      K3S_INSTALLER_URL="file://$SB/installer.sh" K3S_READY_TRIES=2 K3S_READY_SLEEP=0 \
      KUBECONFIG_PATH="$SB/kubeconfig.out" "$SB/bs/k3s-install.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'K3S_NODE_IP'
}

@test "install path: an EMPTY (but readable) kubeconfig is rejected — rc=0 is not enough" {
  # ⚠️ 위 @test는 회수 명령이 **비-0으로 죽는** 경우다. 이건 다른 분기다: k3s가 파일을 만들었지만
  #    아직 쓰지 않은 순간(생성↔쓰기 사이 레이스)에는 `cat`이 rc=0 + 빈 출력을 낸다.
  #    역방향 뮤테이션에서 `[ -s "$_tmp" ]`를 지워도 전 테스트가 green이라 죽은 규칙으로 보였다 —
  #    규칙이 아니라 **테스트가 없었다**. 지우는 대신 이 @test로 살린다.
  _sandbox; touch "$SB/ready"; : > "$SB/kubeconfig.src"
  run _run_install env
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '비어 있다'
  run bash -c "test -e '$SB/kubeconfig.out'"
  [ "$status" -ne 0 ]
}
