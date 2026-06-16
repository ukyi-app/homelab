#!/usr/bin/env bash
# 공유 bats helper. 이 파일 기준 상대 경로로 bootstrap 디렉토리를 resolve한다.
BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BOOTSTRAP_DIR

# 이 마일스톤 전체가 관리하는 단일 OrbStack 머신의 이름 (R3).
export ORB_MACHINE="${ORB_MACHINE:-k3s}"
# gitignored된 kubeconfig 위치 (Task 1.6이 여기에 쓴다).
export KUBECONFIG_PATH="${KUBECONFIG_PATH:-$BOOTSTRAP_DIR/kubeconfig}"
