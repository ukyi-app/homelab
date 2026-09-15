# argocd

**역할** — GitOps 컨트롤러. 이 레포 `main`을 싱크해 전 스택을 운영한다. `root/`의 app-of-apps(`root` Application)가 두 ApplicationSet(`platform-components`, `apps`)과 수동 Application들(`root/apps/*.yaml`)을 소유한다.

자기 레포의 Application·ApplicationSet 소스와 Git generator는 `refs/heads/main`으로 브랜치를 명시한다.
동일한 이름의 tag가 생겨도 GitOps가 다른 커밋을 선택하지 않도록 하는 경계다. main 대상 CI도 이 정확한
값을 검사한다. 외부 Helm 차트의 버전에는 이 브랜치 규약을 적용하지 않는다.

**싱크 Application · sync-wave** — `argocd`는 자기 관리 Application(`platform/argocd/argocd-app.yaml`)으로 **sync-wave -10**, `root`(app-of-apps)는 **-9**. platform-components appset에서는 `platform/argocd/*`가 제외(이중 소유 금지).

**라이브 디버그** — `argo` 스킬(OutOfSync/Progressing 진단, retry 소진 후 명시 sync, 멈춘 operation 종료).

**전역 sync-wave 원장** — [root/SYNC-WAVES.md](root/SYNC-WAVES.md)가 SSOT(M3 소유).

**함정 SSOT** — docs/traps-detail.md: sync-wave는 "이전 wave healthy" 대기(한 Application 내 워크로드가 Secret보다 빠르면 교착), `generatorOptions.annotations`는 KSOPS exec 출력에 미적용, retry 소진 후 비재시도(명시 sync patch), Application zero-value 필드 기재 금지(정규화 플립플롭).
