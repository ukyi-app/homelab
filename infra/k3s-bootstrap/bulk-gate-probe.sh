#!/usr/bin/env sh
# bulk-ssd 백킹 스토어 게이트의 노드 측 절반. `apply-storage.sh`가 권한 상승해 실행하고,
# `tests/test_08-bulk-gate.bats`가 직접 실행해 실제 findmnt/sentinel 로직을 검증한다.
#
# 지키는 불변식 하나: **bulk-ssd가 부트 디스크에 조용히 놓이지 않는다.**
# 그 상태는 cattle 재구축·재포맷에서 사용자 데이터를 잃는다.
#
# ⚠️ 판별 권위가 바뀌었다. OrbStack 시절에는 호스트 측 macOS `diskutil`(Device Location=External)이
#    외장/내장을 판정하고 이 probe는 virtiofs 여부만 봤다 — VM 안에서는 mac 트리 전체가 하나의
#    virtiofs 마운트라 구별이 불가능했기 때문이다. 베어메탈에는 `diskutil`이 없고, 대신 **디바이스
#    정체성**이라는 더 나은 권위가 생겼다: bulk의 백킹 디바이스가 `/`와 같은가.
#
# ⚠️ 그래서 `-T`를 **쓰지 않는다**(OrbStack 시절과 정반대다). `-T`는 경로를 감싸는 마운트로
#    resolve하므로 `/mnt/bulk`가 그냥 루트 위 디렉토리여도 `/`를 돌려준다 — 즉 우리가 잡으려는
#    바로 그 상태를 통과시킨다. 인자 없는 `findmnt <path>`는 그것이 **마운트포인트일 때만** 맞춘다.
#
# 국면 A(D4 한시)에서는 bulk가 루트 LV의 bind 마운트라 디바이스가 `/`와 같다. 그 상태는
# `BULK_TEMPORARY_ALLOWED=1`로 **명시적으로** 허용해야 하고, 허용해도 요란하게 짖는다.
#
# 입력 (env): BULK_STORAGE_PATH · BULK_TEMPORARY_ALLOWED(기본 0)
# 종료: 0 정상 · 11 마운트포인트 아님 · 12 루트와 같은 디바이스(미허용) · 13 쓰기 불가
set -eu
: "${BULK_STORAGE_PATH:?BULK_STORAGE_PATH unset}"
ALLOW="${BULK_TEMPORARY_ALLOWED:-0}"

# ── [1] 마운트포인트인가 ───────────────────────────────────────────────────────────────────
tgt="$(findmnt -no TARGET "$BULK_STORAGE_PATH" 2>/dev/null || true)"
[ "$tgt" = "$BULK_STORAGE_PATH" ] || {
  echo "not a mountpoint: ${BULK_STORAGE_PATH} (findmnt TARGET='${tgt}')" >&2
  echo "  그냥 디렉토리이면 bulk가 부트 디스크에 놓인다 — 재구축·재포맷에서 유실된다." >&2
  echo "  국면 A: mount --bind <루트 위 디렉토리> ${BULK_STORAGE_PATH}   (+ /etc/fstab 등재)" >&2
  echo "  국면 B: 2TB M.2를 ${BULK_STORAGE_PATH}에 마운트" >&2
  exit 11
}

# ── [2] 디바이스 정체성 — 루트와 같은 디스크인가 ───────────────────────────────────────────
# bind 마운트의 SOURCE는 `/dev/…[/sub/path]` 형태다. 대괄호 앞이 디바이스다.
root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
bulk_src="$(findmnt -no SOURCE "$BULK_STORAGE_PATH" 2>/dev/null || true)"
[ -n "$root_src" ] && [ -n "$bulk_src" ] || {
  echo "could not resolve backing devices (root='${root_src}' bulk='${bulk_src}')" >&2
  exit 11
}
root_dev="${root_src%%[*}"
bulk_dev="${bulk_src%%[*}"

if [ "$bulk_dev" = "$root_dev" ]; then
  [ "$ALLOW" = "1" ] || {
    echo "bulk is on the SAME device as / (${bulk_dev}): ${BULK_STORAGE_PATH}" >&2
    echo "  이 상태에서 bulk는 부트 디스크와 운명을 공유한다 — 재포맷·재구축에서 유실되고," >&2
    echo "  eviction의 nodefs 회계에도 함께 들어간다(nuc-port-g2.md B1)." >&2
    echo "  D4 한시 운용이라면 BULK_TEMPORARY_ALLOWED=1 + BULK_MIGRATION_WINDOW_UNTIL을 명시할 것." >&2
    exit 12
  }
  echo "WARN: bulk is on the SAME device as / (${bulk_dev}) — 국면 A(D4 한시) 구성이다." >&2
  echo "WARN: 이 창이 열려 있는 동안 dr-drill은 실행이 거부되고, bulk는 부트 디스크와 함께 사라진다." >&2
fi

# ── [3] 쓰기 가능한가 (local-path helper pod의 root 신원을 반영) ───────────────────────────
s="${BULK_STORAGE_PATH}/.k3s-bulk-sentinel.$$"
if echo homelab-bulk-ok > "$s" 2>/dev/null && grep -q homelab-bulk-ok "$s" 2>/dev/null; then
  rm -f "$s"
else
  rm -f "$s" 2>/dev/null || true
  echo "read/write failed: ${BULK_STORAGE_PATH}" >&2
  exit 13
fi

echo "bulk-probe-ok mount=${BULK_STORAGE_PATH} dev=${bulk_dev} root-dev=${root_dev}"
