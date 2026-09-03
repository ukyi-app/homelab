#!/usr/bin/env bash
# netpol candidate rehearsal — selfHeal off→candidate apply→verify-posture→ALWAYS restore(trap).
# 라벨 미스가 prod로 안 새게: 어떤 종료에도 trap이 selfHeal/main 복원. owner-local(라이브 클러스터·워크트리서).
# ★머지 전 필수 — GitOps selfHeal라 pre-merge verify-posture는 main(broad)을 테스트, candidate가 아니다.
# ⚠️ 인-레포 앱 0인 현 정상 상태(apps/README.md)에서는 **kubelet 프로브 레그만** skip된다 —
#    리허설 자체는 돈다(POSITIVE pg-rw·pg-pooler-rw + NEGATIVE egress deny는 probe()가 자기
#    파드를 띄우므로 앱 파드와 무관하게 실질 판정이다). ipBlock 핀은 gate의
#    `platform/network-policies/prod/test_netpol.bats`가 매 PR에서 따로 강제한다.
# 재사용: COMP/NETPOL/NEEDLE env override로 다른 netpol 리허설(기본=CNPG pooler netpol).
set -euo pipefail
# ⚠️ 이 스크립트는 selfHeal을 끄고 candidate netpol을 apply한다 — **변이**다. 잘못된 클러스터에서
#    돌면 그쪽 prod의 네트워크 정책을 갈아엎고, 아래 trap의 복원도 그 잘못된 쪽에 걸린다.
#    ⇒ trap을 걸기 **전에** 정체성부터 확인한다(D-i). make를 거치지 않는 직접 실행 경로라
#    Makefile 주입이 못 덮는 자리다.
bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infra/k3s-bootstrap/assert-cluster-identity.sh"
APP=network-policies-prod; NS=prod
COMP="${COMP:-network-policies}"; NETPOL="${NETPOL:-allow-egress-to-database}"; NEEDLE="${NEEDLE:-cnpg.io/poolerName}"
restore() {   # trap: 성공/실패/STOP 어떤 EXIT에도 복원(F5)
  echo "==> [trap] 복원: selfHeal on + main(broad) 재싱크"
  kubectl -n argocd patch app "$APP" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}},"operation":{"sync":{}}}' || true
  for _ in $(seq 1 30); do   # Synced/Healthy 대기(~60s)
    s="$(kubectl -n argocd get app "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    h="$(kubectl -n argocd get app "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    [ "$s" = Synced ] && [ "$h" = Healthy ] && break; sleep 2
  done
  if kubectl -n "$NS" get netpol "$NETPOL" -o yaml | grep -q "$NEEDLE"; then
    echo "⚠️ 복원 후에도 candidate 잔존 — 수동 점검(selfHeal/sync)"; else echo "==> 복원 확인(broad)"; fi
}
trap restore EXIT
kubectl -n argocd get app "$APP" >/dev/null                                  # 앱 존재(F3; 없으면 set -e→trap)
kubectl -n argocd patch app "$APP" --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
[ "$(kubectl -n argocd get app "$APP" -o jsonpath='{.spec.syncPolicy.automated.selfHeal}')" = false ]  # 확인(F3)
make -s render COMP="$COMP" | kubectl apply -f -                    # candidate 적용(-s: make 명령 에코 억제 — 안 하면 echo가 line1이라 kubectl YAML 파싱 실패)
kubectl -n "$NS" get netpol "$NETPOL" -o yaml | grep -q "$NEEDLE"  # 반영 확인(F3)
sleep 8                                                                      # kube-router 룰 갭(검증 함정)
# 판정 전 도메인 확인 — 분모를 셋으로 나눈다(형제 `tests/posture/test_network-policy.bats:36-71`과
# 같은 3분할이다. 그 @test가 kubelet 프로브 레그의 실제 판정자이고 여기는 그것을 호출할 뿐이다).
#   (a) 앱 파드는 있는데 라벨 셀렉터가 0건 = **열거 붕괴** → exit 1(전제 불충족이지 skip이 아니다).
#   (b) 앱 파드 0건은 **정상 상태**다(apps/README.md — 인-레포 앱 0개). 그때 닫히는 것은 kubelet
#       프로브 레그 하나뿐인데, 예전엔 그 하나 때문에 리허설 **전체**를 exit 1로 거부했다.
#       prod netpol은 전부 `podSelector: {}`라 verify-posture의 probe() 임시 파드가 그대로 정책
#       아래 놓이고, POSITIVE pg-rw·pg-pooler-rw(F4b — 이 스크립트가 자기 기본 대상으로 삼는
#       바로 그 경로)·NEGATIVE egress deny는 앱 파드 없이도 실질 판정을 낸다. ⇒ 경고만 하고 진행.
#   (c) 앱을 온보딩하면 kubelet 프로브 레그가 자동으로 실질 판정으로 복귀한다(래칫·손 관리 수치 없음).
all_pods="$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -c . || true)"
pods="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name --no-headers 2>/dev/null | grep -c . || true)"
if [ "$all_pods" -gt 0 ] && [ "$pods" -eq 0 ]; then
  echo "✗ 리허설 무효: $NS 파드 ${all_pods}건인데 app.kubernetes.io/name 셀렉터가 0건 — 라벨 드리프트(열거 붕괴)" >&2
  exit 1
fi
if [ "$pods" -eq 0 ]; then
  echo "⚠️ $NS 앱 파드 0건(정상 — 인-레포 앱 0개): kubelet 프로브 레그는 skip된다." >&2
  echo "   ipBlock 자체는 platform/network-policies/prod/test_netpol.bats가 gate에서 핀으로 강제한다." >&2
fi
make verify-posture                                                          # pg-rw + pg-pooler-rw(F4b, fail-closed)
echo "==> rehearsal PASS — candidate 안전(trap이 곧 main 복원 · $NS 앱 파드 ${pods}건 · kubelet 레그는 파드 ≥1일 때만)"
