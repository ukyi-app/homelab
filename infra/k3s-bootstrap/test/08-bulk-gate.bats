#!/usr/bin/env bats
# 진짜 VM 내부 bulk 게이트 로직(bulk-gate-probe.sh)을 직접 검증한다 — orb도 VM도 없이 —
# 그래서 findmnt/sentinel 동작이 실제로 커버된다 (Pass-5 #1 적대적 리뷰 수정). 가짜
# `findmnt`는 OrbStack의 실제 동작을 흉내낸다: mac 공유의 하위 디렉토리는 자체 마운트포인트가
# 아니라서 `-T`로만 resolve된다. 따라서 `-T`를 빼먹은 probe는 이 스위트에서 실패한다.
load test_helper

PROBE="$BOOTSTRAP_DIR/bulk-gate-probe.sh"

setup() {
  STUBDIR="$(mktemp -d)"; WORK="$(mktemp -d)"
  PATH="$STUBDIR:$PATH"; export PATH STUBDIR WORK
  cat >"$STUBDIR/findmnt" <<'EOF'
#!/usr/bin/env sh
# 실제 OrbStack: `findmnt <subdir>`는 아무것도 출력하지 않고 1로 종료; `findmnt -T <subdir>`만 resolve된다.
[ "${FINDMNT_NORESOLVE:-0}" = "1" ] && exit 1
hasT=0; for a in "$@"; do [ "$a" = "-T" ] && hasT=1; done
[ "$hasT" = "1" ] || exit 1
echo "${FINDMNT_FSTYPE:-virtiofs}"
EOF
  chmod +x "$STUBDIR/findmnt"
}
teardown() { rm -rf "$STUBDIR" "$WORK"; }

@test "passes on a writable virtiofs share (and thereby proves the probe uses findmnt -T)" {
  BULK_EXTERNAL_MOUNT="/mnt/mac/Volumes/homelab" BULK_STORAGE_PATH="$WORK/bulk" run sh "$PROBE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"external-bulk-probe-ok"* ]]
  [ -d "$WORK/bulk" ]                       # 베이스 디렉토리가 생성됨
  [ -z "$(ls -A "$WORK/bulk")" ]            # sentinel이 정리됨
}

@test "exit 11 when the mount cannot be resolved (fails closed)" {
  FINDMNT_NORESOLVE=1 BULK_EXTERNAL_MOUNT="/mnt/mac/Volumes/homelab" BULK_STORAGE_PATH="$WORK/bulk" run sh "$PROBE"
  [ "$status" -eq 11 ]
}

@test "exit 12 when the share is not virtiofs (e.g. an ext4 VM-disk path)" {
  FINDMNT_FSTYPE=ext4 BULK_EXTERNAL_MOUNT="/var/lib/rancher/k3s-storage/bulk" BULK_STORAGE_PATH="$WORK/bulk" run sh "$PROBE"
  [ "$status" -eq 12 ]
}

@test "exit 13 when the bulk path cannot be created (unwritable parent)" {
  ro="$WORK/ro"; mkdir -p "$ro"; chmod 555 "$ro"
  BULK_EXTERNAL_MOUNT="/mnt/mac/Volumes/homelab" BULK_STORAGE_PATH="$ro/bulk" run sh "$PROBE"
  [ "$status" -eq 13 ]
  chmod 755 "$ro"
}

@test "errors when required env is missing" {
  run sh "$PROBE"
  [ "$status" -ne 0 ]
}
