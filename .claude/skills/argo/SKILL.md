---
name: argo
description: 이 홈랩 레포에서 ArgoCD를 운영·디버그할 때 사용. sync/health 상태 확인, OutOfSync/Progressing 원인 진단(SSA atomic list, sync-wave 교착), retry 소진 후 명시 sync, 멈춘 operation 종료. read-only 기본 — 변이 patch는 사용자 확인 후. ArgoCD·sync-wave·OutOfSync·교착 키워드에 반응.
---

# ArgoCD 운영·디버그 (homelab)

이 레포는 GitOps SSOT다 — **클러스터 변경 권위는 ArgoCD(git→main)**다. `kubectl apply`로 라이브를 직접 고치지 않는다(드리프트·교착 유발). 이 스킬은 read-only 진단과, 사람이 승인한 좁은 운영 patch만 다룬다.

## 전제
- 라이브 접근: `eval "$(make kubeconfig)"` (= `KUBECONFIG=$PWD/infra/k3s-bootstrap/kubeconfig`).
- 변이(sync/terminate)는 **실행 전 명령을 사용자에게 제시하고 확인**받는다(bypassPermissions 환경이라 프롬프트가 없다).
- 시크릿/`*.enc.yaml` 평문은 출력하지 않는다.

## 1차 진입점 — make 타겟
```bash
make argo-status              # 전 Application: SYNC / HEALTH / 멈춘 OPERATION phase
make argo-sync APP=<name>     # retry 소진 후 명시 sync 트리거
make argo-terminate APP=<name># 멈춘 operation 종료(phase=Terminating)
make argo-wait [APP=<name>]   # Healthy 될 때까지 대기(미지정=전체)
make render COMP=<comp>       # KSOPS 풀 렌더로 매니페스트 확인(복호 읽기, 라이브 무영향)
```

## 진단 체크리스트 (증상 → 원인 → 조치)
- **OutOfSync인데 diff가 서버 주입 기본값** → SSA + atomic list 함정. HTTPRoute `parentRefs`/`backendRefs`, STS `volumeClaimTemplates`는 서버가 group/kind/weight·status를 주입해 영구 OutOfSync가 된다. 조치: manifest에 기본값 명시하거나, status까지 주입되는 vCT는 `ignoreDifferences`(+`RespectIgnoreDifferences=true`). `kubectl get <res> -o yaml`의 `managedFields`로 주입 주체 확인.
- **Application이 Progressing에서 안 끝남(30분+)** → cross-Application sync-wave 교착 의심. sync-wave는 "이전 wave가 healthy"를 기다리며 **Application 경계를 넘지 못한다**. `platform/argocd/root/SYNC-WAVES.md` 표로 순서 확인(`test_sync_wave_ledger.bats`가 드리프트를 게이트). 한 Application 안에서 워크로드(-6)가 Secret(0)보다 빠르면 영구 교착 — 내부 wave는 꼭 필요할 때만. `generatorOptions.annotations`는 KSOPS(exec) 출력엔 적용되지 않는다.
- **실패 리소스가 재시도 안 됨** → ArgoCD는 retry 소진 후 자동 재시도하지 않는다. `make argo-sync APP=<x>`로 명시 sync. 멈춘 op는 `make argo-terminate APP=<x>`.
- **SSA가 sync 거부(중복 env 키/스키마 밖 필드)** → k8s SSA는 중복 env·스키마 외 필드를 거부한다(argo-helm `ARGOCD_CONTROLLER_REPLICAS`, barman ObjectStore `spec.env` 사례).
- **zero-value 필드 플립플롭(generation 폭주)** → Application spec의 zero-value(`directory.recurse: false` 등)는 컨트롤러 정규화가 매번 삭제 → selfHeal과 충돌. zero-value 필드는 기재하지 않는다.

## 막힌 operation 강제 종료(직접 patch — 마지막 수단)
make 타겟이 안 들으면(예: status subresource 형태 차이) AGENTS.md 검증 형태:
```bash
kubectl -n argocd patch app <x> --type merge -p '{"operation":{"sync":{}}}'   # 명시 sync
# 멈춘 op: status.operationState.phase=Terminating patch
```
실행 전 사용자 확인. argocd CLI(v3.x)는 server.insecure 세션 마찰로 기본 미사용.

