# T08c 내부 UI 짧은 주소 `go/`

- 단계: P2 플랫폼 구축 (2026-10-20 추가, D-30)
- 상태: 대기
- 명세: [../spec.md](../spec.md) §5.1 D-30
- 설계: [../platform/design.md](../platform/design.md) C.3.5 "짧은 주소", F D-30
- Blocked by: T08a
- 선행 결정: D-08 (확정(사용자 2026-10-18): 내부 UI `<서비스>.<tailnet>.ts.net`), D-23 (확정(사용자 2026-10-17): tailnet 이름·Tailscale IP는 저장소 밖), D-30 (확정(사용자 2026-10-20): tailnet 전용 리다이렉터 `go`, 기기 즐겨찾기는 두지 않음)
- 연결 AC: 없음(이 티켓의 완료 조건으로 판정)
- 수행: 에이전트 + 사람 (ACL Terraform apply(owner 로컬), 맥·아이폰 셀룰러 확인. 명세 §11)

## 목표

tailnet 안에서 `go/<이름>`을 치면 `https://<이름>.<tailnet>.ts.net`으로 넘어가게 한다. 새 인증서, DNS 쓰기 자격, 공개 DNS 레코드 없이 짧은 입력만 더한다.

## 선행 조건

- T08a: Tailscale operator와 ProxyClass `homelab-proxy`, Argo CD·AdGuard의 tailnet Ingress, Tailscale ACL root(`infra/tailscale`)의 apply 경로.

## 범위

### 리다이렉터

- 위치는 `platform/go`(새 Application) 또는 `platform/tailscale` 로컬 차트 중 하나로 정한다. 새 ns를 쓰면 restricted PSA로 두고, ESO를 쓰면 `infisical-platform` 스토어의 ns 허용 목록에 더한다.
- Deployment 1개. 작은 정적 웹 서버(예: nginx unprivileged), 이미지 digest 고정, 상태·PVC·Tailscale 자격 없음.
- 규칙: 첫 경로 조각이 DNS 라벨 `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`이고 `<접두><이름>`이 63자 이하면 `302 https://<접두><이름>.<tailnet 도메인><나머지 경로>`, 쿼리 유지. 그 밖의 경로는 404, `/`는 사용법 한 줄. 대상 호스트는 늘 한 라벨 + tailnet 도메인이라 열린 리다이렉트가 아니다(`go/evil.com`은 점 때문에 404). 영구 캐시되는 301은 쓰지 않는다.
- 접두는 `cluster.tailscale.prefix`다. 운영은 `""`, VM은 `vm-`라 VM의 `vm-go/argocd`는 `vm-argocd`로 보낸다.
- tailnet 도메인은 저장소에 두지 않고(D-23) 실행 때 넣는다. Infisical `homelab`(prod) `/platform/go`의 키(예: `TAILNET_DOMAIN`)를 ESO로 env에 넣는다. VM용 `homelab-dev`(dev)의 같은 경로에도 같은 키를 둔다(시나리오 13의 키 대조). 값이 비었거나 `<이름>.ts.net` 꼴이 아니면 파드가 시작하지 않게 한다. 자기 Service 상태에서 읽는 안은 API 서버 egress와 RBAC가 늘어 쓰지 않는다.
- Service `type: LoadBalancer`, `loadBalancerClass: tailscale`, 어노테이션 `tailscale.com/hostname: <접두>go`, `tailscale.com/tags: tag:k8s-go`. 포트는 80 하나다. **443은 열지 않는다.** 브라우저가 `https://go`를 먼저 시도하면 인증서 오류가 아니라 연결 거부로 끝나야 한다. Ingress로 내지 않는다(operator Ingress는 443과 전체 이름 인증서만 다뤄 `go/`가 TLS 실패, 설계 C.3.5).
- NetworkPolicy: egress는 없다. ingress 출처는 실제 경로를 관찰해 정한다. 고정한 v1.104.1의 L3 프록시는 프록시의 tailnet 주소를 Service ClusterIP로 DNAT할 뿐 새 연결을 만들지 않으므로, 백엔드가 보는 출처는 `tailscale` ns 프록시 파드가 아니라 원래 tailnet 주소나 노드가 SNAT한 주소일 수 있다(Ingress 프록시와 다르다). `namespaceSelector`로 프록시 파드만 허용하면 정상 요청이 막힐 수 있다. 관찰한 출처만 허용하고, 허용 출처(tailnet 기기)와 비허용 출처(다른 ns의 시험 파드)를 모두 시험한다.
- k3s servicelb가 이 Service를 건너뛰는지 확인한다. svclb DaemonSet이 생기면 노드 LAN에 80이 열린다(PR #779의 교훈).
- 접근 로그에 경로·쿼리를 남기지 않는다. 남은 경로·쿼리에 토큰이나 인증 코드가 들어갈 수 있고, 파드 로그는 T08b의 수집기가 14일 보관한다. 접근 로그를 끄거나 경로·쿼리를 뺀 형식으로만 남긴다.
- 함정은 설정 옆 주석으로 남긴다: 443을 열지 않는 이유, 301을 쓰지 않는 이유, 접근 로그에서 경로·쿼리를 빼는 이유, 이름이 HSTS preload 최상위 도메인(`app`, `dev` 등)과 겹치면 안 되는 이유.

### ACL (`infra/tailscale`, owner 로컬 apply)

- tagOwners에 `"tag:k8s-go": ["tag:k8s-operator"]`, acls에 `autogroup:member → tag:k8s-go:80`을 더한다. 모든 프록시에 80을 여는 `tag:k8s:80`으로 넓히지 않는다.
- 이 두 줄은 T08a의 D-11 (c) ACL PR에 함께 넣어 한 번에 적용한다(ACL 적용을 집에서 한 번으로 줄이려고). T08c 착수 때 이미 적용돼 있으면 확인만 한다. 따로 적용해야 하면 apply 전 정책 사본을 저장소 밖에 두고, plan이 이 두 줄만 바꾸는지 본다.

### 이름 예약

- `go`와 `vm-go`는 두 클러스터 모두에서 앱 내부 이름(`internal.name`)과 다른 tailnet 기기 이름으로 쓰지 않는다. 운영 앱이 `vm-go`를 먼저 쓰면 VM 리다이렉터가 그 이름을 못 받는다. T10 공유 차트의 이름 검사에 예약어로 넣는다(T10 범위에 적어 둠).

### 문서

- 설계 C.3.5 "준비 확인"에 `go/argocd` 확인을 더하고, 운영 문서에 사용법 한 줄을 둔다(실제 tailnet 이름 없이).

## 완료 조건

- 맥(Safari, Chrome)에서 `go/argocd` → Argo CD 로그인 화면, `go/adguard` → AdGuard 로그인 화면.
- 아이폰 Safari(셀룰러, Tailscale 켬)에서 스킴 없이 친 `go/argocd`가 열린다. 이것이 D-30의 사용자 목표라 필수다. 검색어로 가거나 HTTPS로 바뀌어 실패하면 완료로 치지 않고, 원인과 `http://go/argocd` 결과를 기록한 뒤 구현이나 D-30을 사용자와 다시 정한다.
- 경로·쿼리 유지: `go/argocd/applications?x=1` → 같은 경로·쿼리. 그 시험 쿼리 문자열이 파드 로그에 없다(T08b 뒤라면 로그 저장소에도 없다).
- 거부: `go/evil.com`·`go/a.b`는 404, `https://go/`는 연결 실패(인증서 경고가 아님).
- `go` 파드를 0으로 줄여도 전체 주소 `https://argocd.<tailnet>.ts.net`은 그대로 열리고, 되돌리면 `go/`가 돌아온다.
- Tailscale을 끈 기기에서는 `go`가 풀리지 않는다. 노드 LAN `192.168.117.15`에 80이 새로 열리지 않는다(svclb 없음).
- tailnet 기기 목록에서 프록시 이름이 정확히 `go`다(접미 번호 없음).
- VM: `values-vm.yaml`로 렌더한 Service hostname이 `vm-go`이고 리다이렉트 접두가 `vm-`다. VM 실접속(`vm-go/argocd` → `vm-argocd`)은 T13 시나리오 13에서 확인한다.
- 저장소·이미지·로그에 tailnet 이름이 없다(gitleaks, D-23).
- approvals.md에 Infisical 키 등록(프로젝트·환경·경로·키 이름과 승인·등록 결과, 값은 쓰지 않음. `homelab`/prod와 `homelab-dev`/dev 둘), ACL apply, 병합을 기록한다.

## 되돌리는 방법

- root의 자식 Application은 기본으로 `resources-finalizer`를 붙이지 않아서(`platform/root/templates/_helpers.tpl`, 명시한 `edge-probe`만 예외) Application만 끄거나 지우면 Deployment·Service가 남고, Service가 있는 동안 프록시 기기도 남는다. 그래서 Application이 살아 있을 때 `go` 매니페스트를 지우는 PR을 병합해 prune으로 Service·프록시 기기가 사라졌는지 확인하고, 그다음 Application과 ACL 두 줄을 지우는 PR과 apply를 한다. 전체 주소는 그대로라 사용자에게 남는 영향은 짧은 입력이 없어지는 것뿐이다.

## 범위 밖

- 링크를 손으로 등록·편집하는 golink 기능, HTTPS 짧은 주소, 기기 즐겨찾기(D-30이 두지 않음).
