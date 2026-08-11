#!/usr/bin/env bash
# 멱등한 호스트 기반 계층 오케스트레이터: 전제를 확인하고, 정확한 플래그로 k3s를 설치하고,
# 스토리지를 apply한 뒤, 라이브 계약을 단언한다. 각 단계가 개별적으로 멱등하므로 재실행은 안전하다.
#
# ⚠️ **순서가 계약이다** — 베어메탈에서 순서 제약은 완화가 아니라 **강화**됐다:
#   · `--tls-san`/`--node-ip`은 **설치 시점에만** 정할 수 있다(사후 교정 = serving cert 삭제).
#   · 타임존·resolved 스텁은 k3s 기동·첫 이미지 pull **이전**이어야 한다 — 사후 교정이 원리적으로
#     어렵다(고치러 들어가려면 이름해석이 필요한데 그게 바로 깨진 것이다). 그래서 [1]이 맨 앞이다.
#   · 그러므로 [1]은 "확인"이지 "설정"이 아니다. 설정은 **`host-config.sh --apply`**의 몫이고
#     (실파일 트리 `host-config/` + 설치기 — `cloud-init.yaml`의 후계), 여기서는 **그것이
#     끝났는지**만 본다. 안 끝났으면 요란하게 멈춘다.
#     ⚠️ `--apply`를 이 파이프라인에 넣지 않는 이유: owner의 sudo가 패스워드를 요구해(실측)
#        비대화형으로 못 돈다. 노드 프로비저닝 시 사람이 한 번 돌리는 경로다.
#
# HOSTUP_BINDIR 시임 — 하위 스크립트를 stub으로 가려 **순서를 라이브 없이 증명**한다
# (tests/test_08-host-up.bats). 이 시임이 이 파일의 유일한 테스트 가능성 원천이다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${HOSTUP_BINDIR:-$SCRIPT_DIR}"

echo "===> [1/4] 호스트 전제 확인 (타임존 · resolved · 노드 IP)"
"$BIN/host-preflight.sh"
echo "===> [2/4] k3s 설치 + kubeconfig"
"$BIN/k3s-install.sh"
echo "===> [3/4] StorageClasses"
# ⚠️ **아직 이식 전이다.** `apply-storage.sh`는 여전히 `orb -m` + macOS `diskutil`로 외장 SSD를
#    검사한다(bulk 게이트). 2TB M.2 물리 장착 전에는 "디바이스 정체성" 설계를 실물로 확정할 수
#    없어서 의도적으로 남겨 뒀다 — 계획서 §3.3 · nuc-port-g2.md B7.
#    베어메탈에서 이 줄에 도달하면 실패한다. 그래도 **[1]이 먼저 막으므로** 반쯤 설정된 노드에
#    k3s가 올라가는 일은 없다(그게 이 순서의 요점이다).
"$BIN/apply-storage.sh"
echo "===> [4/4] 라이브 계약 검증"
"$BIN/verify-cluster.sh"

echo "===> 호스트 substrate 기동 완료. export KUBECONFIG=$SCRIPT_DIR/kubeconfig"
