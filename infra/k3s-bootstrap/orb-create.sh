#!/usr/bin/env bash
# k3s를 호스팅하는 단 하나의 OrbStack VM을 생성한다. 멱등: 머신이 이미 있으면
# 두 번째 실행은 no-op이다. memory/cpu 상한은 OrbStack 전역 설정이므로(R3),
# 예산상의 상한(§9/§10)으로 무조건 설정한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
ORB_MACHINE="${ORB_MACHINE:-k3s}"
CLOUD_INIT="$SCRIPT_DIR/cloud-init.yaml"

command -v orb >/dev/null 2>&1 || { echo "FAIL: 'orb' not on PATH (install OrbStack)." >&2; exit 2; }
[ -f "$CLOUD_INIT" ] || { echo "FAIL: missing $CLOUD_INIT" >&2; exit 2; }

# OrbStack 전역 상한 — 예약이 아니라 상한이다 (OrbStack은 유휴 RAM을 돌려준다).
echo "==> Setting global OrbStack caps: ${ORB_MEMORY_MIB} MiB / ${ORB_CPU} vCPU"
orb config set memory_mib "$ORB_MEMORY_MIB"
orb config set cpu "$ORB_CPU"

if orb list 2>/dev/null | awk 'NF && $1 != "NAME" {print $1}' | grep -qx "$ORB_MACHINE"; then
  echo "==> Machine '${ORB_MACHINE}' already exists — skipping create (idempotent)."
else
  echo "==> Creating Debian ${DEBIAN_RELEASE} ${DEBIAN_ARCH} machine '${ORB_MACHINE}'…"
  # Apple Silicon의 OrbStack은 arm64가 기본이다; 배포판은 명시적으로 지정한다.
  orb create "debian:${DEBIAN_RELEASE}" "$ORB_MACHINE" -c "$CLOUD_INIT"
fi

# k3s를 기본 머신으로 만들어 `orb -m`이 선택사항이 되게 한다(다른 곳에서는 명시적으로 사용).
orb default "$ORB_MACHINE" >/dev/null 2>&1 || true
echo "==> Done. Verify with: infra/k3s-bootstrap/orb-guard.sh"
