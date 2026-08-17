#!/usr/bin/env bats
# D-i(2026-08-12) 클러스터 정체성 — 각인(kubeconfig-identity.sh)과 대조(assert-cluster-identity.sh).
#
# 왜 이 스위트가 있는가: 라이브 Mac 클러스터와 NUC 클러스터의 kubeconfig는 경로·포트가 같고,
# #449 이후 k8s 노드명까지 `k3s`로 같다. 두 클러스터를 가르는 것은 (1) kubeconfig가 스스로
# 부르는 이름 (2) 라이브 노드 InternalIP (3) 라이브 노드 architecture 셋뿐이다.
# ⚠️ 이름은 **레포의 어떤 코드도 읽지 않는다**(--context 참조 0건). assert-cluster-identity.sh가
#    그 이름을 읽는 첫 코드이고, 그래서 이름 분리는 이 스크립트가 있어야 비로소 값을 갖는다.
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"; export STUBDIR
  IDENT="$BOOTSTRAP_DIR/kubeconfig-identity.sh"
  ASSERT="$BOOTSTRAP_DIR/assert-cluster-identity.sh"
  export IDENT ASSERT
  # k3s가 실제로 만드는 kubeconfig 형태(라이브 실측). `default`가 정확히 6곳이다.
  cat > "$STUBDIR/kc.yaml" <<'EOF'
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: RkFLRQ==
    server: https://127.0.0.1:6443
  name: default
contexts:
- context:
    cluster: default
    user: default
  name: default
current-context: default
kind: Config
users:
- name: default
  user:
    client-certificate-data: RkFLRQ==
EOF
}
teardown() { rm -rf "$STUBDIR"; }

count_named() { grep -cE "^(  name|- name|    cluster|    user|current-context): $1\$" "$2" || true; }

# ── 각인 ────────────────────────────────────────────────────────────────────────────────
@test "stamps all six identity fields, leaving nothing named default" {
  run bash "$IDENT" --file "$STUBDIR/kc.yaml" --name homelab-nuc
  [ "$status" -eq 0 ]
  [ "$(count_named homelab-nuc "$STUBDIR/kc.yaml")" = "6" ]
  [ "$(count_named default "$STUBDIR/kc.yaml")" = "0" ]
}

@test "is idempotent — a second run changes nothing and still passes" {
  bash "$IDENT" --file "$STUBDIR/kc.yaml" --name homelab-nuc
  before="$(md5 -q "$STUBDIR/kc.yaml" 2>/dev/null || md5sum "$STUBDIR/kc.yaml" | cut -d' ' -f1)"
  run bash "$IDENT" --file "$STUBDIR/kc.yaml" --name homelab-nuc
  [ "$status" -eq 0 ]
  after="$(md5 -q "$STUBDIR/kc.yaml" 2>/dev/null || md5sum "$STUBDIR/kc.yaml" | cut -d' ' -f1)"
  [ "$before" = "$after" ]
}

@test "refuses a partially stamped file instead of finishing the job silently" {
  # 부분 각인은 "누가 손으로 고치다 말았다"는 신호다 — 조용히 마저 채우면 그 사실이 사라진다.
  bash "$IDENT" --file "$STUBDIR/kc.yaml" --name homelab-nuc
  sed -i.bak 's/^current-context: homelab-nuc$/current-context: default/' "$STUBDIR/kc.yaml"
  rm -f "$STUBDIR/kc.yaml.bak"
  run bash "$IDENT" --file "$STUBDIR/kc.yaml" --name homelab-nuc
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '형태가 예상과 다르다'
}

@test "does not touch a namespace field that happens to say default" {
  # ⚠️ 값만 보고 치환하면 `namespace: default`를 개명해 컨텍스트의 기본 네임스페이스를 망가뜨린다.
  #    레포의 Mac 사본은 그 자리에 argocd를 갖고 있다 — 필드를 앵커로 못박아야 하는 이유다.
  sed -i.bak 's/^    user: default$/    namespace: default\n    user: default/' "$STUBDIR/kc.yaml"
  rm -f "$STUBDIR/kc.yaml.bak"
  run bash "$IDENT" --file "$STUBDIR/kc.yaml" --name homelab-nuc
  [ "$status" -eq 0 ]
  grep -q '^    namespace: default$' "$STUBDIR/kc.yaml"
}

@test "rewrites the server URL only when asked" {
  bash "$IDENT" --file "$STUBDIR/kc.yaml" --name homelab-nuc
  grep -q 'server: https://127.0.0.1:6443' "$STUBDIR/kc.yaml"
  run bash "$IDENT" --file "$STUBDIR/kc.yaml" --name homelab-nuc --server https://100.109.208.81:6443
  [ "$status" -eq 0 ]
  grep -q 'server: https://100.109.208.81:6443' "$STUBDIR/kc.yaml"
}

@test "rejects a name carrying regex or delimiter metacharacters" {
  # 이름은 sed 치환부에 들어간다 — 메타문자를 받으면 조용히 다른 것을 쓴다.
  run bash "$IDENT" --file "$STUBDIR/kc.yaml" --name 'homelab#nuc'
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '쓸 수 없는 문자'
}

@test "refuses a file whose shape it does not recognise (two clusters)" {
  printf 'clusters:\n- cluster:\n    server: https://a:6443\n  name: default\n- cluster:\n    server: https://b:6443\n  name: default\n' > "$STUBDIR/two.yaml"
  run bash "$IDENT" --file "$STUBDIR/two.yaml" --name homelab-nuc
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q '형태가 예상과 다르다'
}

# ── 대조 ────────────────────────────────────────────────────────────────────────────────
# versions.env를 source하는 스크립트라 env 주입으로는 핀을 못 덮는다(export가 이긴다).
# 레포 사본의 versions.env를 고쳐 쓰는 것이 이 레포의 확립된 관용구다.
mk_bs() {
  cp -R "$BOOTSTRAP_DIR" "$STUBDIR/bs"
  sed -i.bak "s/^export K3S_KUBECONFIG_NAME=.*/export K3S_KUBECONFIG_NAME=\"$1\"/" "$STUBDIR/bs/versions.env"
  sed -i.bak "s/^export K3S_NODE_IP=.*/export K3S_NODE_IP=\"$2\"/" "$STUBDIR/bs/versions.env"
  sed -i.bak "s/^export K3S_NODE_ARCH=.*/export K3S_NODE_ARCH=\"$3\"/" "$STUBDIR/bs/versions.env"
  rm -f "$STUBDIR/bs/versions.env.bak"
  cat > "$STUBDIR/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"current-context"*) cat "$STUBDIR/ctx.txt" ;;
  *"nodeInfo.architecture"*|*"InternalIP"*) printf '%s|%s' "$(cat "$STUBDIR/ip.txt")" "$(cat "$STUBDIR/arch.txt")" ;;
esac
exit 0
EOF
  chmod +x "$STUBDIR/kubectl"
  PATH="$STUBDIR:$PATH"; export PATH
}

@test "passes when name, node IP and architecture all match the pins" {
  mk_bs homelab-nuc 192.168.117.15 amd64
  echo "homelab-nuc" > "$STUBDIR/ctx.txt"; echo "192.168.117.15" > "$STUBDIR/ip.txt"; echo "amd64" > "$STUBDIR/arch.txt"
  run bash "$STUBDIR/bs/assert-cluster-identity.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'cluster-identity OK'
}

@test "fails when the context names a different cluster" {
  mk_bs homelab-nuc 192.168.117.15 amd64
  echo "default" > "$STUBDIR/ctx.txt"; echo "192.168.117.15" > "$STUBDIR/ip.txt"; echo "amd64" > "$STUBDIR/arch.txt"
  run bash "$STUBDIR/bs/assert-cluster-identity.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'context가'
}

@test "fails when the live node IP is not the pinned one (netpol allows depend on it)" {
  mk_bs homelab-nuc 192.168.117.15 amd64
  echo "homelab-nuc" > "$STUBDIR/ctx.txt"; echo "192.168.139.92" > "$STUBDIR/ip.txt"; echo "amd64" > "$STUBDIR/arch.txt"
  run bash "$STUBDIR/bs/assert-cluster-identity.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'InternalIP'
}

@test "fails when the architecture differs — that is a different machine" {
  # 이름과 IP는 사람이 바꿀 수 있지만 arch는 기기가 바뀌어야 바뀐다. 가장 튼튼한 축이다.
  mk_bs homelab-nuc 192.168.117.15 amd64
  echo "homelab-nuc" > "$STUBDIR/ctx.txt"; echo "192.168.117.15" > "$STUBDIR/ip.txt"; echo "arm64" > "$STUBDIR/arch.txt"
  run bash "$STUBDIR/bs/assert-cluster-identity.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -q 'architecture'
}

@test "warn mode keeps a read-only path alive but never prints OK" {
  # 새벽 3시에 관측 수단까지 잠그지 않는다. 다만 경고를 내고도 OK를 찍으면 그 줄만 보는 사람에게
  # 거짓 신호가 된다 — rc는 0이되 OK는 없어야 한다.
  mk_bs homelab-nuc 192.168.117.15 amd64
  echo "default" > "$STUBDIR/ctx.txt"; echo "192.168.139.92" > "$STUBDIR/ip.txt"; echo "arm64" > "$STUBDIR/arch.txt"
  run bash "$STUBDIR/bs/assert-cluster-identity.sh" --warn
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'WARN: cluster-identity'
  run bash -c "bash '$STUBDIR/bs/assert-cluster-identity.sh' --warn 2>&1 | grep -c 'cluster-identity OK'"
  [ "$output" = "0" ]
}

@test "the warn banner never uses the SKIP marker shape (it would promote the caller to authoritative)" {
  # tools/check-guard-authority.ts의 SKIP_EMISSION 정규식이 'SKIP: <이름>:' 을 보면 그 타겟을
  # mirror에서 권위 venue로 승격시킨다. 이 스크립트는 그 문자열을 내면 안 된다.
  run grep -nE '(echo|printf)[^\n]*SKIP: [a-z0-9-]+:' "$BOOTSTRAP_DIR/assert-cluster-identity.sh"
  [ "$status" -ne 0 ]
}

@test "the node command shim keeps sudo as its default (D-i decision, not an accident)" {
  # K3S_RUN 기본값은 D-i에서 **결정된** 것이다(정본 실행처 = NUC). 비대화형이 필요하면 호출자가
  # ssh root@… 로 덮는다. 기본값이 조용히 바뀌면 그 결정이 사라지므로 한 줄로 고정한다.
  grep -qE '^K3S_RUN="\$\{K3S_RUN:-sudo\}"$' "$BOOTSTRAP_DIR/verify-cluster.sh"
  grep -qE '^K3S_RUN="\$\{K3S_RUN:-sudo\}"$' "$BOOTSTRAP_DIR/k3s-install.sh"
}
