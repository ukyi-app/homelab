#!/usr/bin/env bash
# 렌더링(고정된 arm64 helper 이미지 + bulk 노드 경로 치환) 후 듀얼 local-path provisioner와
# 두 StorageClass를 클러스터에 apply한다. bulk-ssd를 연결하기 전에 외부 SSD가 VM 내부에서
# 실제로 마운트되어 있고 쓰기 가능한지 게이트한다 — bulk-ssd가 조용히 VM 디스크에 자리잡았다가
# cattle 재구축 때 유실되는 일을 막기 위함.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
export KUBECONFIG="${KUBECONFIG_PATH:-$SCRIPT_DIR/kubeconfig}"
ORB_MACHINE="${ORB_MACHINE:-k3s}"

command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl not on PATH." >&2; exit 2; }

# --- bulk-ssd 백킹 스토어 게이트 -----------------------------------------------------------------
# bulk-ssd는 OrbStack이 VM으로 공유하는 외부 SSD(virtiofs)에 있어야 하며, 절대 VM/내장
# 디스크에 조용히 놓이면 안 된다(cattle 재구축 시 유실). 독립적인 검사 두 가지, 둘 다 필수:
#   (1) 호스트 측 (macOS `diskutil`): $BULK_EXTERNAL_HOST_PATH 가 물리적으로 외장 디스크에
#       있는지. virtiofs FSTYPE으로는 외장 SSD와 부트 디스크를 구분할 수 없으므로(VM에서는
#       mac 트리 전체가 하나의 virtiofs 마운트), 외장/내장 판별은 여기서 권위 있게 결정한다.
#   (2) VM 측 (orb 경유 bulk-gate-probe.sh): 공유가 virtiofs로 resolve되고(findmnt -T)
#       bulk 경로가 VM 내부에서 root로 쓰기 가능한지.
# SSD 없이 dev/이너루프로 돌릴 때의 탈출구: BULK_ALLOW_VM_DISK=1 이면 VM 디스크로
# 폴백한다(재구축 시 비영속).
gate_fail() {
  {
    echo "FAIL: $1"
    echo "      This guards bulk-ssd from silently landing on the VM disk and being lost on rebuild."
    echo "      Fix: create the external 'homelab' APFS volume + grant OrbStack access — see docs/runbooks/external-ssd.md."
    echo "      Dev/inner-loop without the SSD: BULK_ALLOW_VM_DISK=1 $0"
  } >&2
  exit 1
}
if [ "${BULK_ALLOW_VM_DISK:-0}" = "1" ]; then
  echo "WARN: BULK_ALLOW_VM_DISK=1 — bulk-ssd uses the VM disk (${BULK_VM_DISK_FALLBACK}); data is LOST on a VM rebuild. Dev/inner-loop only." >&2
  BULK_STORAGE_PATH="$BULK_VM_DISK_FALLBACK"
else
  # (1) 호스트 측 외장 디바이스 검사.
  command -v diskutil >/dev/null 2>&1 || gate_fail "'diskutil' not on PATH — needed to confirm ${BULK_EXTERNAL_HOST_PATH} is an external disk (or set BULK_ALLOW_VM_DISK=1)."
  # `|| true`: `set -e`+pipefail 아래에서 경로가 없으면 `diskutil`이 non-zero로 종료하는데,
  # 이게 없으면 아래의 요란한 gate_fail에 닿기 전에 여기서 (조용히) 스크립트가 중단된다.
  loc="$(diskutil info "$BULK_EXTERNAL_HOST_PATH" 2>/dev/null | awk -F': *' '/Device Location/{print $2}' | tr -d '[:space:]' || true)"
  echo "==> Host check: ${BULK_EXTERNAL_HOST_PATH} Device Location = ${loc:-<none>}"
  [ "$loc" = "External" ] || gate_fail "${BULK_EXTERNAL_HOST_PATH} is not on an EXTERNAL disk (Device Location='${loc:-not mounted}'). Create the 'homelab' APFS volume on the external SSD — a bare dir on the internal disk does NOT count."
  # (2) VM 측 virtiofs + 쓰기 가능성 probe (실제 로직은 bulk-gate-probe.sh에 있다).
  command -v orb >/dev/null 2>&1 || gate_fail "'orb' not on PATH — needed to verify the external bulk SSD from inside the VM (or set BULK_ALLOW_VM_DISK=1)."
  echo "==> VM check: probing ${BULK_EXTERNAL_MOUNT} (path ${BULK_STORAGE_PATH}) inside VM '${ORB_MACHINE}'…"
  orb -m "$ORB_MACHINE" -u root env \
        BULK_EXTERNAL_MOUNT="$BULK_EXTERNAL_MOUNT" BULK_STORAGE_PATH="$BULK_STORAGE_PATH" \
        sh -s < "$SCRIPT_DIR/bulk-gate-probe.sh" \
    || gate_fail "external bulk SSD not a writable virtiofs share at ${BULK_EXTERNAL_MOUNT} inside VM '${ORB_MACHINE}'."
  echo "==> External bulk SSD OK (external disk, virtiofs, writable)."
fi
export BULK_STORAGE_PATH

# LOCAL_PATH_HELPER_IMAGE + BULK_STORAGE_PATH 만 템플릿 대상이다; envsubst를 이 두 변수로
# 제한해 다른 것(예: setup 스크립트 내부의 $VOL_DIR)이 덮어써지지 않게 한다.
render() {
  if command -v envsubst >/dev/null 2>&1; then
    # envsubst의 SHELL-FORMAT 인자는 ${VAR} 이름의 리터럴 목록이다 — 작은따옴표 필수.
    # shellcheck disable=SC2016
    envsubst '${LOCAL_PATH_HELPER_IMAGE} ${BULK_STORAGE_PATH}' < "$1"
  else
    sed -e "s#\${LOCAL_PATH_HELPER_IMAGE}#${LOCAL_PATH_HELPER_IMAGE}#g" \
        -e "s#\${BULK_STORAGE_PATH}#${BULK_STORAGE_PATH}#g" "$1"
  fi
}

echo "==> Applying local-path provisioner (helper image: ${LOCAL_PATH_HELPER_IMAGE}; bulk path: ${BULK_STORAGE_PATH})…"
render "$SCRIPT_DIR/storage/local-path-provisioner.yaml" | kubectl apply -f -

echo "==> Applying StorageClasses…"
kubectl apply -f "$SCRIPT_DIR/storage/storageclass-standard.yaml"
kubectl apply -f "$SCRIPT_DIR/storage/storageclass-bulk-ssd.yaml"

echo "==> Storage applied. Verify with: kubectl get sc"
