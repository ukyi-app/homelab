#!/usr/bin/env bash
# 멱등한 호스트 기반 계층 오케스트레이터: 단 하나의 OrbStack VM을 올리고, 정확한
# 플래그로 k3s를 설치하고, 스토리지를 apply한 뒤, 단일 머신 규칙을 단언한다.
# 각 단계가 개별적으로 멱등하므로 host-up.sh 재실행은 안전하다(cattle).
# ⚠️ 단, cloud-init은 머신 생성 1회만 — cloud-init.yaml 편집은 재생성 전까진 미반영(orb-create가 경고).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${HOSTUP_BINDIR:-$SCRIPT_DIR}"

echo "===> [1/4] OrbStack VM"
"$BIN/orb-create.sh"
echo "===> [2/4] k3s install + kubeconfig"
"$BIN/k3s-install.sh"
echo "===> [3/4] StorageClasses"
"$BIN/apply-storage.sh"
echo "===> [4/4] R3 single-machine health check"
"$BIN/orb-guard.sh"

echo "===> Host substrate is up. Next: export KUBECONFIG=$SCRIPT_DIR/kubeconfig"
