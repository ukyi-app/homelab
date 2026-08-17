#!/usr/bin/env bash
# netpol candidate rehearsal — selfHeal off→candidate apply→verify-posture→ALWAYS restore(trap).
# 라벨 미스가 prod로 안 새게: 어떤 종료에도 trap이 selfHeal/main 복원. owner-local(라이브 클러스터·워크트리서).
# ★머지 전 필수 — GitOps selfHeal라 pre-merge verify-posture는 main(broad)을 테스트, candidate가 아니다.
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
# 판정 전 도메인 확인 — verify-posture의 프로브 단언은 prod 라벨 파드 위에서만 의미가 있다.
# 파드 0건(DR 재구축 직후·전 앱 scale-0·라벨 드리프트)이면 candidate가 kubelet 프로브를 막아도
# 'rehearsal PASS'가 찍히고 그대로 머지된다. ⚠️ skip이 아니라 **전제 불충족**이라 exit 1이다
# (exit 4를 쓰면 호출자가 '평가 안 함, 정상'으로 읽는다 — 정반대 뜻).
pods="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name --no-headers 2>/dev/null | grep -c . || true)"
[ "$pods" -ge 1 ] || { echo "✗ 리허설 무효: $NS 앱 파드 0건 — verify-posture가 vacuous. 앱 배포 후 재실행" >&2; exit 1; }
make verify-posture                                                          # pg-rw + pg-pooler-rw(F4b, fail-closed)
echo "==> rehearsal PASS — candidate 안전(trap이 곧 main 복원 · $NS 앱 파드 ${pods}건 위에서 판정)"
