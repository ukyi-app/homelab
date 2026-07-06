# 베스포크 플랫폼 컴포넌트 체크리스트

공유 차트(`platform/charts/app`) 골든패스 밖의 컴포넌트를 `platform/<comp>/`로 손복제할 때 최소셋.
계보: adguard → homepage → cache → files(4번째). 근거는 `docs/decisions/0004-golden-path-rule-of-two.md`.
각 항목은 라이브에서 검증된 함정에 대응한다(누락 시 재발) — `docs/traps-detail.md` 교차참조.

## 1. 네임스페이스 · PSA · Prune
- [ ] `platform/namespaces/prod/namespaces.yaml`에 전용 NS + `pod-security.kubernetes.io/enforce:
      restricted` + `argocd.argoproj.io/sync-options: Prune=false`(appset 대상 NS는 platform/namespaces
      소유 — 컴포넌트가 prune하지 못하게).
- [ ] NS 회귀 가드 bats(`platform/namespaces/prod/test_<comp>_ns.bats`, homepage/files 패턴).

## 2. 워크로드 · 보안 컨텍스트
- [ ] `runAsNonRoot`·`readOnlyRootFilesystem`·`allowPrivilegeEscalation:false`·`drop:[ALL]`·
      `seccompProfile:RuntimeDefault`. 쓰기 필요 시 PVC/emptyDir만. RWO PVC면 `strategy: Recreate`
      (단일 노드 볼륨 교착 회피). 비루트 PVC 쓰기엔 `fsGroup`.
- [ ] private GHCR면 `imagePullSecrets:[{name: ghcr-pull}]` + `ghcr-pull.sealed.yaml`.

## 3. 노출 (netpol 트리오 + 공개 host)
- [ ] NetworkPolicy 트리오: default-deny egress + allow-dns egress(kube-system/kube-dns) +
      allow-ingress-from-gateway(namespaceSelector gateway). 함정: NetworkPolicy egress 포트는
      DNAT 후 targetPort.
- [ ] 내부 host는 `<comp>.home.<도메인>`(Gateway web-internal-tls 리스너 규약 — 내부 인입은 tailscale
      passthrough→:8443만). HTTPRoute internal은 `sectionName: web-internal-tls`에 붙인다.
- [ ] 공개 노출은 **`infra/cloudflare/reserved-hosts.json`→dns.tf `platform_hosts`**(apps.json 아님
      — apps.json은 audit-orphans가 apps/ 부재를 차단한다). 공개 HTTPRoute + reserved-hosts.json 등록.

## 4. 이미지 핀 레인 (자동 bump 합류)
- [ ] `platform/<comp>/prod/source-repo`(= `ukyi-app/<comp>`) + `.image-pin.json`
      (`{file, path, autoDeploy}`) — bump-poll 2차 순회가 발견해 인라인 핀을 자동 bump한다.
      누락 시 릴리스마다 수동 bump PR로 회귀.
- [ ] 이미지는 `<repo>:sha-<gitsha>@sha256:<digest>` 인라인 핀(불변). autoDeploy=false면 fail-closed
      승인 PR(단, propose-pr은 주기마다 새 PR을 여니 사용자-데이터 무변이 컴포넌트는 true 권장).

## 5. 원장 · 알림 · 렌더 가드
- [ ] `docs/memory-ledger.md`에 컴포넌트 행 추가(limit 합계 ≤ 예산, CI 강제).
- [ ] ArgoCD notifications 구독(배포/저하 telegram) + 워크로드-불가용 vmalert 룰 커버
      (files/adguard/homepage 공백 클래스 — `kube_deployment_status_condition` 일괄 룰).
- [ ] 렌더 bats(homepage 패턴: kustomize build + kubeconform) + 컴포넌트 기능 bats 최소셋.
