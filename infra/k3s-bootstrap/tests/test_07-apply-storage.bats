#!/usr/bin/env bats
load test_helper

setup() {
  STUBDIR="$(mktemp -d)"; RENDERED="$STUBDIR/rendered.yaml"
  PATH="$STUBDIR:$PATH"; export PATH STUBDIR RENDERED
  source "$BOOTSTRAP_DIR/versions.env"
  cat >"$STUBDIR/kubectl" <<'EOF'
#!/usr/bin/env bash
# '-f -'로 파이프되든 '-f <file>'로 읽히든, apply된 모든 매니페스트를 $RENDERED에
# 누적해 단언이 apply 전체 집합을 보게 한다 (StorageClass apply는 stdin이 아니라
# 파일을 쓰며, 파이프된 provisioner를 덮어쓰면 안 된다).
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
  # 게이트의 호스트 측 `diskutil` 검사를 stub한다 (기본은 External).
  # DISKUTIL_STUB_INTERNAL=1 은 /Volumes/homelab 이 내장 디스크의 맨 디렉토리인 상황을 시뮬레이션한다.
  cat >"$STUBDIR/diskutil" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "info" ]; then
  if [ "${DISKUTIL_STUB_INTERNAL:-0}" = "1" ]; then echo "   Device Location:           Internal"
  else echo "   Device Location:           External"; fi
fi
exit 0
EOF
  chmod +x "$STUBDIR/diskutil"
  # 게이트의 VM 측 `orb` probe를 stub해 스위트를 밀폐(hermetic)시킨다 (실제 VM 없음). probe는
  # stdin으로 파이프된다(orb … sh -s < bulk-gate-probe.sh); 실제 probe 로직은 08-bulk-gate.bats가 커버한다.
  # ORB_STUB_FAIL=1 은 VM 내부에서 virtiofs가 아니거나 쓰기 불가한 외장 SSD를 시뮬레이션한다.
  cat >"$STUBDIR/orb" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true                 # 파이프된 probe 스크립트를 소비한다
[ "${ORB_STUB_FAIL:-0}" = "1" ] && { echo "stub: external bulk not available" >&2; exit 11; }
exit 0
EOF
  chmod +x "$STUBDIR/orb"
  export KUBECONFIG_PATH="$STUBDIR/kubeconfig"; : > "$KUBECONFIG_PATH"
}
teardown() { rm -rf "$STUBDIR"; }

@test "renders manifests with the helper image substituted (no literal placeholder)" {
  run "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -eq 0 ]
  run grep -F '${LOCAL_PATH_HELPER_IMAGE}' "$RENDERED"
  [ "$status" -ne 0 ]                          # 플레이스홀더는 사라져야 한다
  run grep -F "$LOCAL_PATH_HELPER_IMAGE" "$RENDERED"
  [ "$status" -eq 0 ]                          # 실제 digest 존재
}

@test "applies both StorageClasses" {
  run "$BOOTSTRAP_DIR/apply-storage.sh"
  grep -q 'name: standard' "$RENDERED"
  grep -q 'name: bulk-ssd' "$RENDERED"
}

@test "renders the external-SSD bulk path into the provisioner (no literal placeholder)" {
  run "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -eq 0 ]
  run grep -F '${BULK_STORAGE_PATH}' "$RENDERED"
  [ "$status" -ne 0 ]                          # 플레이스홀더 치환됨
  run grep -F "$BULK_STORAGE_PATH" "$RENDERED" # 실제 외장 경로 존재
  [ "$status" -eq 0 ]
}

@test "aborts when the host volume is on an INTERNAL disk (diskutil external-device check)" {
  # virtiofs FSTYPE만으로는 절대 할 수 없는 검사다: 내장 디스크 위의 맨 /Volumes/homelab
  # 디렉토리가 이게 없으면 통과해서 bulk가 VM 디스크에 놓이게 된다.
  DISKUTIL_STUB_INTERNAL=1 run "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on an EXTERNAL disk"* ]]
  [ ! -s "$RENDERED" ]
}

@test "aborts when the VM-side probe fails (no silent VM-disk fallback)" {
  ORB_STUB_FAIL=1 run "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"external bulk SSD"* ]]
  [ ! -s "$RENDERED" ]                          # 게이트가 apply보다 먼저 돈다 — 렌더된 것 없음
}

@test "BULK_ALLOW_VM_DISK=1 skips the gate and renders the VM-disk fallback path" {
  ORB_STUB_FAIL=1 BULK_ALLOW_VM_DISK=1 run "$BOOTSTRAP_DIR/apply-storage.sh"
  [ "$status" -eq 0 ]                           # orb stub이 실패해도 게이트는 건너뛰어짐
  run grep -F "$BULK_VM_DISK_FALLBACK" "$RENDERED"
  [ "$status" -eq 0 ]                           # 폴백 경로가 bulk provisioner에 렌더됨
}
