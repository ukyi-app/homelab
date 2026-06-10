#!/usr/bin/env bats
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"; PATH="$STUBDIR:$PATH"; export PATH STUBDIR
  export KUBECONFIG_PATH="$STUBDIR/kubeconfig"; : > "$KUBECONFIG_PATH"
  # Healthy defaults; individual tests override via env files the stub reads.
  : > "$STUBDIR/pods.txt"          # kube-system pod names, one per line
  echo "svclb-traefik-abc"      >> "$STUBDIR/pods.txt"   # servicelb LB pod (NOT a traefik controller)
  echo "coredns-xyz"            >> "$STUBDIR/pods.txt"
  echo "true"  > "$STUBDIR/encryption.txt"               # secrets-encrypt enabled
  echo "Ready" > "$STUBDIR/nodestatus.txt"
  printf 'standard\nbulk-ssd\n' > "$STUBDIR/sc.txt"

  cat >"$STUBDIR/orb" <<'EOF'
#!/usr/bin/env bash
# Emulate `orb -m k3s -u root k3s secrets-encrypt status`
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
  # Regression guard for the precise '^traefik-' match: the healthy fixture already
  # carries svclb-traefik-abc, so a passing run proves no false positive.
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
  # The script asserts the FLAG contract (svclb pods are M3-on-demand). A bad
  # install script that disables servicelb must trip the guard.
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
