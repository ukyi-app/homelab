#!/usr/bin/env bash
# R3 헬스체크: OrbStack 환경에 "$ORB_MACHINE" 이름의 머신이 정확히 하나만,
# running 상태로 존재함을 단언한다. OrbStack 메모리 상한은 전역이라,
# 여분의 머신/컨테이너는 k3s VM의 11 GiB를 조용히 가로챈다.
# 이후 마일스톤들이 게이트로 재사용한다 — 의존성 없이 유지할 것 (jq 금지).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"
ORB_MACHINE="${ORB_MACHINE:-k3s}"

if ! command -v orb >/dev/null 2>&1; then
  echo "FAIL: 'orb' not found on PATH — is OrbStack installed?" >&2
  exit 2
fi

# `orb list`(OrbStack 2.x)는 파이프/non-TTY에서는 헤더를 출력하지 않고, TTY에서는
# "NAME …" 헤더를 출력할 수 있다. 둘 다 견디게: 빈 줄과 헤더 행을 제거한다.
mapfile -t rows < <(orb list 2>/dev/null | awk 'NF && $1 != "NAME"')

count="${#rows[@]}"
if [ "$count" -ne 1 ]; then
  echo "FAIL: expected exactly one OrbStack machine, found ${count} (R3 global-cap rule)." >&2
  printf '  %s\n' "${rows[@]}" >&2
  exit 1
fi

name="$(awk '{print $1}' <<<"${rows[0]}")"
state="$(awk '{print $2}' <<<"${rows[0]}")"

if [ "$name" != "$ORB_MACHINE" ]; then
  echo "FAIL: the single machine is '${name}', expected '${ORB_MACHINE}'." >&2
  exit 1
fi
if [ "$state" != "running" ]; then
  echo "FAIL: machine '${name}' is '${state}', expected 'running'." >&2
  exit 1
fi

echo "OK: exactly one OrbStack machine '${name}' is running."
