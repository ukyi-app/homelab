#!/usr/bin/env sh
# bulk-ssd 백킹 스토어 게이트의 VM 내부 절반 (Pass-5 Open Item #1). apply-storage.sh가 이것을
# root로 k3s VM에 파이프한다(`orb -m k3s -u root env … sh -s < bulk-gate-probe.sh`); 또한
# test/08-bulk-gate.bats가 직접 실행해 실제 findmnt/sentinel 로직이 실제로 검증되게 한다.
#
# bulk 경로가 OrbStack macOS virtiofs 공유 위에 있고 VM 내부에서 쓰기 가능한지를 확인한다
# (local-path helper pod의 root 신원을 그대로 반영). 외장/내장 판별은 하지 않는다 —
# OrbStack에서는 mac 트리 전체가 하나의 virtiofs 마운트라 virtiofs FSTYPE으로는 외장 SSD와
# 부트 디스크를 구분할 수 없다; 그 판별은 호스트 측에서 apply-storage.sh가 macOS `diskutil`
# (Device Location: External)로 수행한다.
#
# 입력 (env): BULK_EXTERNAL_MOUNT, BULK_STORAGE_PATH.
set -eu
: "${BULK_EXTERNAL_MOUNT:?BULK_EXTERNAL_MOUNT unset}"
: "${BULK_STORAGE_PATH:?BULK_STORAGE_PATH unset}"

# findmnt는 반드시 -T를 써야 한다: OrbStack에서 mac 공유의 하위 디렉토리는 자체 마운트포인트가
# 아니라서, 그냥 `findmnt <subdir>`는 아무것도 출력하지 않고 1로 종료한다. -T는 이를 포함하는 마운트로 resolve한다.
fstype="$(findmnt -no FSTYPE -T "$BULK_EXTERNAL_MOUNT" 2>/dev/null || true)"
[ -n "$fstype" ] || { echo "not resolvable to a mount: $BULK_EXTERNAL_MOUNT" >&2; exit 11; }
[ "$fstype" = virtiofs ] || { echo "not the OrbStack mac share (fstype=$fstype): $BULK_EXTERNAL_MOUNT" >&2; exit 12; }

mkdir -p "$BULK_STORAGE_PATH" || { echo "mkdir failed: $BULK_STORAGE_PATH" >&2; exit 13; }
s="$BULK_STORAGE_PATH/.k3s-bulk-sentinel.$$"
if echo homelab-bulk-ok > "$s" 2>/dev/null && grep -q homelab-bulk-ok "$s" 2>/dev/null; then
  rm -f "$s"
else
  rm -f "$s" 2>/dev/null || true
  echo "read/write failed: $BULK_STORAGE_PATH" >&2
  exit 14
fi
echo external-bulk-probe-ok
