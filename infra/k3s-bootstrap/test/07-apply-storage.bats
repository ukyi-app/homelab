#!/usr/bin/env bats
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"; RENDERED="$STUBDIR/rendered.yaml"
  PATH="$STUBDIR:$PATH"; export PATH STUBDIR RENDERED
  source "$BOOTSTRAP_DIR/versions.env"
  cat >"$STUBDIR/kubectl" <<'EOF'
#!/usr/bin/env bash
# Accumulate every applied manifest into $RENDERED, whether piped via '-f -' or
# read from '-f <file>', so assertions see the full applied set (StorageClass
# applies use files, not stdin, and must not clobber the piped provisioner).
if [ "$1" = "apply" ]; then
  src=""
  while [ $# -gt 0 ]; do
    if [ "$1" = "-f" ]; then src="$2"; shift; fi
    shift
  done
  if [ "$src" = "-" ] || [ -z "$src" ]; then
    cat >> "$RENDERED"
  else
    cat "$src" >> "$RENDERED"
  fi
fi
exit 0
EOF
  chmod +x "$STUBDIR/kubectl"
  export KUBECONFIG_PATH="$STUBDIR/kubeconfig"; : > "$KUBECONFIG_PATH"
}
teardown() { rm -rf "$STUBDIR"; }

@test "renders manifests with the helper image substituted (no literal placeholder)" {
  run "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -eq 0 ]
  run grep -F '${LOCAL_PATH_HELPER_IMAGE}' "$RENDERED"
  [ "$status" -ne 0 ]                          # placeholder must be gone
  run grep -F "$LOCAL_PATH_HELPER_IMAGE" "$RENDERED"
  [ "$status" -eq 0 ]                          # real digest present
}

@test "applies both StorageClasses" {
  run "$BOOTSTRAP_DIR/apply-storage.sh"
  grep -q 'name: standard' "$RENDERED"
  grep -q 'name: bulk-ssd' "$RENDERED"
}
