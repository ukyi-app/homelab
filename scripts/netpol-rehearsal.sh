#!/usr/bin/env bash
# netpol candidate rehearsal — selfHeal off→candidate apply→verify-posture→ALWAYS restore(trap).
# 라벨 미스가 prod로 안 새게: 어떤 종료에도 trap이 selfHeal/main 복원. owner-local(라이브 클러스터·워크트리서).
# ★머지 전 필수 — GitOps selfHeal라 pre-merge verify-posture는 main(broad)을 테스트, candidate가 아니다.
set -euo pipefail
APP=network-policies-prod; NS=prod
restore() {   # trap: 성공/실패/STOP 어떤 EXIT에도 복원(F5)
  echo "==> [trap] 복원: selfHeal on + main(broad) 재싱크"
  kubectl -n argocd patch app "$APP" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}},"operation":{"sync":{}}}' || true
  for _ in $(seq 1 30); do   # Synced/Healthy 대기(~60s)
    s="$(kubectl -n argocd get app "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    h="$(kubectl -n argocd get app "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    [ "$s" = Synced ] && [ "$h" = Healthy ] && break; sleep 2
  done
  if kubectl -n "$NS" get netpol allow-egress-to-database -o yaml | grep -q 'cnpg.io/poolerName'; then
    echo "⚠️ 복원 후에도 candidate 잔존 — 수동 점검(selfHeal/sync)"; else echo "==> 복원 확인(broad)"; fi
}
trap restore EXIT
kubectl -n argocd get app "$APP" >/dev/null                                  # 앱 존재(F3; 없으면 set -e→trap)
kubectl -n argocd patch app "$APP" --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
[ "$(kubectl -n argocd get app "$APP" -o jsonpath='{.spec.syncPolicy.automated.selfHeal}')" = false ]  # 확인(F3)
make render COMP=network-policies | kubectl apply -f -                       # candidate 적용
kubectl -n "$NS" get netpol allow-egress-to-database -o yaml | grep -q 'cnpg.io/poolerName'  # 반영 확인(F3)
sleep 8                                                                      # kube-router 룰 갭(검증 함정)
make verify-posture                                                          # pg-rw + pg-pooler-rw(F4b, fail-closed)
echo "==> rehearsal PASS — candidate 안전(trap이 곧 main 복원)"
