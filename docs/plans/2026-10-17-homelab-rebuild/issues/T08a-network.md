# T08a 네트워크·DNS·외부 공개

- 단계: P2 플랫폼 구축 (재분해 T05 2026-10-18)
- 상태: 진행 중 (2026-10-20 착수. Terraform root 셋 PR #772, cert-manager·Traefik·Tailscale operator PR, AdGuard 작업 중. 사람: tailnet HTTPS 켜짐 확인, ACL·DNS 현재 값 저장소 밖 보관, operator OAuth 발급·등록)
- 명세: [../spec.md](../spec.md) §4.5
- 설계: [../platform/design.md](../platform/design.md) E.1 E4a, E.3, C.3.4~C.3.6, C.3.8, C.3.9, C.8
- Blocked by: T07, T09
- 선행 결정: D-08 (확정(사용자 2026-10-18): 내부 UI `*.ts.net`, Tailscale DNS (b′)), D-11 (확정(사용자 2026-10-18, T05): 설계 F D-11 표 그대로, Tailscale ACL (a)), D-12 (확정(사용자 2026-10-18, T05): 노드 DNS drop-in은 T06이 남기고 T07이 덮어씀), D-28 (확정(사용자 2026-10-18): Terraform state 잠금 시험), 공개 DNS 방식·Argo CD 공개 webhook·백업 보존 (확정(사용자 2026-10-18, T05): 설계 F "추가 확인")
- 연결 AC: AC-P6, AC-P12
- 수행: 에이전트 + 사람 (Cloudflare·Tailscale 콘솔, Terraform apply(owner 로컬), Tailscale operator OAuth 발급, 집 Wi-Fi·셀룰러 기기 확인. 명세 §11)

## 목표

CI/CD와 앱이 올라갈 네트워크 바닥을 세운다. 공개 경로(Cloudflare 터널, Traefik), 내부 UI(`*.ts.net`), Tailscale ACL·DNS, AdGuard, cert-manager, 백업 버킷을 만들고 Terraform state 잠금을 확인한다.

## 선행 조건

- T07: Argo CD가 main을 동기화하고, root에 이 티켓의 Application 자리가 있다. 노드 DNS가 공용 DNS 직접이다.
- T09: Infisical과 ESO가 있어 터널 토큰과 operator OAuth를 ESO로 받는다. Terraform 자격 셋이 `homelab-admin`에 있다(아래 "필요한 자격").
- 사람 작업(설계 E4a): Terraform apply(owner 로컬, `infisical run`), Tailscale operator OAuth client 발급, tailnet HTTPS 인증서 켜기, Tailscale DNS Terraform 첫 apply(콘솔의 현재 값을 기록 → 그대로 옮긴 HCL로 새 state에 import → plan 무변경 확인) 뒤 D-08 (b′) 값으로 바꾸는 PR과 apply, NUC 키 만료 해제 확인, AdGuard 내보내기 파일 제공.

## 입력

- T06이 내보낸 옛 AdGuard 라이브 설정 (비밀값 제외).
- 옛 저장소(`2d2054a`)에서 가져올 것(설계 E4a): P03, P06, P07, P12, P21, P22의 실측 설정값, H5, B.8 "E4" 함정 중 AdGuard·Tailscale·Cloudflare.

## 범위

### 외부 공개 (`infra/cloudflare`, `platform/cloudflared`, `platform/traefik`)

- Cloudflare 터널과 인그레스. 공개 webhook 수신 경로를 포함한다(아래). `.app` 최상위 도메인 전체가 브라우저 HSTS preload 목록에 있어 `ukyi.app` 아래 모든 이름은 처음 접속하는 브라우저에서도 HTTPS 전용이다. 그래서 공개 이름은 처음부터 유효한 인증서의 HTTPS로 띄운다. 평문 HTTP나 자체 서명 인증서는 브라우저가 열어 주지 않는다. zone HSTS 헤더(includeSubDomains, 180일)는 이와 별개로 유지한다(D-11).
- 터널: 원격 관리 터널을 새로 만든다. ingress 규칙은 Terraform 한 곳에만 둔다: `*.ukyi.app`과 `ukyi.app` → `http://traefik.traefik.svc.cluster.local:80`, 마지막은 `http_status:404`. 커넥터는 1개(롤링 업데이트 `maxSurge: 1`)다. 단일 노드라 복제본을 늘려도 고가용성은 아니다. cloudflared는 2026.10.1을 이미지 태그 + digest로 고정한다(2026.8.0·8.1은 쓰지 않는다). 같은 토큰으로 커넥터가 둘 붙으면 공개 요청이 비결정적으로 나뉘므로 옛 터널을 쓰지 않는다. 클러스터에는 Cloudflare API 토큰을 두지 않고 터널 토큰만 ESO로 받는다.
- 공개 DNS: 와일드카드 `*` CNAME 하나와 apex를 터널로(proxied) 둔다. 확정(사용자 2026-10-18, T05). 어느 이름이 공개되는지는 Git의 Ingress가 정하고, 모르는 host는 Traefik이 404다. 원격 관리 터널이 와일드카드 hostname을 받는지는 [미검증] U01이다. 안 되면 공개 host마다 Terraform DNS 레코드를 둔다(사람 apply, 앱 등록 PR에 안내). 이 레코드는 운영 터널만 가리킨다.
- Traefik: Service는 ClusterIP라 LAN·tailnet에서 직접 닿지 않는다. Ingress class `traefik` 하나, 엔트리포인트 `web` 하나다. Gateway API와 내부 TLS 리스너는 두지 않는다. 버전은 이 티켓 시작 때 정해 고정한다(U14). 공개 host는 `^[a-z0-9-]+\.ukyi\.app$` 한 단계만이다(Universal SSL은 apex와 첫 단계 하위 도메인만 덮는다. 공유 차트 schema는 T10).
- zone 설정 9개: 값을 유지한 채 새 Terraform으로 가져온다(HSTS includeSubDomains·nosniff 180일, preload 끔, `always_use_https`, TLS 1.2 최소, TLS 1.3, `browser_check`, `security_level` medium 등, 설계 F D-11 표).
- WAF(Free, 사용자 규칙 5개, 정규식 불가): 규칙 1 "host가 `hooks.ukyi.app`이고 (path ≠ `/github` 또는 method ≠ POST)면 Block". `eq`·`ne`만 쓴다. 나머지는 zone 기본 보호를 상속한다. 일부 값은 apply에서만 400이 나므로 apply는 사람이 보며 한다.
- Argo CD 공개 webhook은 두지 않는다. Argo CD는 60초 폴링(`timeout.reconciliation` 60s, jitter 0. T07이 설정)으로 main을 본다. 확정(사용자 2026-10-18, T05). 그래서 이 티켓의 공개 경로에는 Argo CD로 가는 webhook이 없다.

### 공개 webhook 수신 경로 (AC-P12 자리, 설계 C.8·E.3)

- `https://hooks.ukyi.app/github` → Cloudflare(WAF 규칙 1) → 터널 → Traefik Ingress(host `hooks.ukyi.app`, path `/github` Exact) → 봇 Service. POST 한 경로만 받는다.
- 봇이 오기 전에는 시험 수신기(HMAC `X-Hub-Signature-256` 검증만 하는 작은 서비스)가 이 경로를 받는다. 봇 배포 때 시험 수신기를 지운다.
- 출처 확인은 HMAC 상수 시간 비교다(봇이 검증). GitHub webhook은 사용자 헤더를 못 붙여 Cloudflare Access Service Auth로 거를 수 없다. IP 제한은 선택이고, 넣으면 GitHub 대역 갱신 담당을 정한다.

### 내부 UI와 Tailscale operator (D-08, `platform/tailscale`)

- 내부 UI (D-08). Tailscale operator Ingress의 `<서비스>.<tailnet>.ts.net`으로 띄운다(UI마다 단독 프록시). `*.home.ukyi.app` 내부 이름, AdGuard rewrite, 내부 와일드카드 인증서, cert-manager DNS-01 Cloudflare 토큰, traefik-ts는 두지 않는다. tailnet HTTPS 인증서를 켜면 기기 이름과 tailnet DNS 이름이 공개 CT 로그에 실리므로, 공개해도 되는 기기 이름만 쓴다.
- 이 티켓이 내는 내부 Ingress는 Argo CD와 AdGuard 관리 화면이다. Grafana는 T08b가 같은 operator로 낸다. 이름은 `argocd`, `grafana`, `adguard`다.
- operator: chart 1.104.1. OAuth client(Services·Devices Core·Auth Keys write, 태그 `tag:k8s-operator`. Services는 2026-10-20 공식 설치 문서 기준으로 더함)는 Infisical `homelab`의 `/platform/tailscale`에서 ESO로 받는다. ns `tailscale`은 privileged다. ProxyClass로 프록시 메모리 상한을 둔다. operator Ingress reconcile은 메타데이터만 바뀐 변경을 무시하므로, 바꿀 때는 Ingress를 다시 만든다.
- 전체 이름(`https://argocd.<tailnet>.ts.net`)만 열린다. 짧은 이름은 TLS 연결 실패다. 프록시는 인증서를 새로 받지 못하면 핸드셰이크를 실패시키고, 갱신 실패가 이어져도 만료까지 약 30일 여유가 있다. 막혔을 때 비상 경로는 `kubectl -n argocd port-forward svc/argocd-server 8080:80` 같은 port-forward다(설계 C.3.5).

### Tailscale ACL (D-11 (a), `infra/tailscale`)

- 새 ACL은 `autogroup:self` 허용과 ssh 규칙을 유지한다. 빠지면 운영자의 NUC 원격 접속이 끊긴다.
- D-11 (a) 확정(사용자 2026-10-18, T05): NUC는 태그 없는 사용자 기기다. 규칙은 설계 C.3.5 예시다: `autogroup:member → autogroup:self:*` accept, `autogroup:member → tag:k8s:443` accept(내부 UI 프록시), ssh는 `autogroup:member → autogroup:self` accept에 `autogroup:nonroot`·`root`. tagOwners는 `tag:k8s-operator`: `autogroup:admin`, `tag:k8s`: `tag:k8s-operator`.
- D-08 (b′)에서 운영자 기기가 NUC의 AdGuard Home(`:53`)에 닿는 길도 이 self 규칙이다. NUC를 `tag:nuc`로 태그하면(D-11 (c)) `autogroup:member → tag:nuc:53` ACL 규칙이 필요하다. 빠뜨려도 공용 서버가 답해 증상이 없다.
- (c)로 바꿀 조건은 이 티켓에서 U28 결과로 다시 본다: U28 시험에서 파드가 NUC 주소로 운영자 기기에 닿는 것이 확인되고, egress 정책이 없는 플랫폼 파드를 모두 막기 어렵다고 판단될 때다. 이때 (b)의 `check`를 함께 고를 수 있다. 조건에 맞으면 사용자에게 (c) 전환을 묻고, 바꾸면 설계 C.3.5 예시와 이 티켓의 검증을 함께 고친다.
- 남는 위험: self 규칙은 NUC에서 운영자의 다른 기기로 가는 모든 포트도 연다. 대응은 공유 차트 egress의 tailnet 대역 제외(T10)와 작업자 공간의 init 규칙(T08b)이다. 그 밖의 플랫폼 파드는 각 구성 요소의 egress 정책에 같은 대역 제외를 두고, egress 정책이 없는 파드에는 이 위험이 남는다. 노트북을 잃으면 비밀번호 없는 root 접속까지 열린다(D-11 (a)의 대가).

### Tailscale DNS (D-08, `infra/tailscale-dns`)

- 목표 값: Override local DNS 켬, 전역 nameserver = [NUC Tailscale IP(AdGuard Home), `94.140.14.14`, `94.140.15.15`](AdGuard 공용 DNS, AdGuard Home 기본값과 같은 AdGuard DNS filter), C-05의 임시 Cloudflare 4개 삭제, MagicDNS 켬, HTTPS 켬, `use_with_exit_node` 기본 끔. 목적은 Tailscale을 켠 기기가 집 안팎 어디서든 차단을 받고, NUC 장애 때도 공용 서버가 차단하며 답하는 것이다. 대가 다섯은 명세 §4.5 "Tailscale DNS"에 있다.
- Terraform `tailscale_dns_configuration`(provider v0.29.2, 정식)으로 관리한다. `data.tailscale_devices`로 hostname이 일치하는 기기를 받아 precondition을 건다: 정확히 1대, 소유자·태그 기대값, `key_expiry_disabled`. IPv4는 `100.` 대역으로 골라낸다. `tailscale_dns_nameservers`와 함께 쓰지 않는다. 기대 소유자 값은 공개 HCL에 쓰지 않고 변수(`homelab-admin`의 `/terraform/tailscale`)로 받는다(D-23).
- 이 자원은 DNS 설정 전체를 소유한다. 첫 apply 전에 콘솔의 현재 값을 기록하고, 그 값을 그대로 옮긴 HCL로 새 state에 import한 뒤(import 블록, provider가 지원) plan 무변경을 확인하고 목표 값으로 바꾼다. import 없이 새 state로 plan하면 생성 계획이 나온다. 선언하지 않은 콘솔 값(nameserver, split DNS, search path)은 첫 apply에서 지워지고, `override_local_dns`를 빠뜨리면 기본 false라 기기가 로컬 DNS를 계속 쓴다(plan은 정상).
- DNS는 ACL과 나눈 별도 root `infra/tailscale-dns`(state 키 `v2/tailscale-dns/terraform.tfstate`)에 두고 리소스에 `prevent_destroy`를 건다. NUC가 없을 때 precondition 오류가 ACL apply까지 막지 않게 하려는 것이다. 조건부(`count`)는 쓰지 않는다. NUC가 없는 동안 apply가 DNS 설정 전체의 삭제를 계획해 공용 폴백과 Override까지 사라지기 때문이다. NUC가 tailnet에 없는 동안은 이 root를 apply하지 않는다. Override를 켠 상태에서 AdGuard가 죽어도 공용 서버가 답하므로 Terraform 실행 기기의 DNS 문제는 작다.
- NUC를 Tailscale에 다시 등록하면 키 만료가 기본값(켜짐)으로 돌아오고 Tailscale IP가 바뀔 수 있다. 키 만료를 해제한 뒤 apply하면 data source가 새 IP를 쓴다. 만료가 켜진 채면 precondition이 apply를 멈춘다.
- 이 HCL과 import는 [미검증] U34다(문서·소스로만 맞춰 썼다). 안 되면 콘솔에서 한 번 설정하고 `bootstrap.md`에 값의 출처와 확인 명령(`tailscale dns status --all`)을 적는 방식으로 돌아간다(IaC 밖, 드리프트는 사람 확인).

### AdGuard와 노드 DNS (`platform/adguard`)

- AdGuard. 같은 LAN IP `192.168.117.15`의 `:53`으로 서빙해 공유기 설정을 그대로 쓴다. 노드 자신의 DNS에는 함정이 두 개 있다.
  - Tailscale 쪽: k3s 노드 자신은 tailnet 전역 nameserver를 받지 않게 한다.
  - LAN 쪽: 공유기의 주 DNS가 노드 위 AdGuard라서, 노드가 DHCP DNS를 쓰면 "노드 → 공유기 → 노드 위 AdGuard" 순환이 생긴다. 콜드스타트 때 AdGuard가 아직 없으면 이름 해석이 막히고 이미지 pull까지 막힌다.
  - 막는 법: 노드는 공용 DNS를 직접 쓴다. 옛 host-config의 resolved drop-in과 `tailscale set --accept-dns=false`가 하던 일이다. D-12 확정(사용자 2026-10-18, T05)대로 T06이 이 drop-in(H5)을 남겼고 T07이 Git의 호스트 설정으로 덮어썼다. 이 티켓은 그 설정이 있는지 확인한다(`resolvectl status`에 `1.1.1.1 9.9.9.9`, `tailscale dns status` → "Tailscale DNS: disabled", 명세 §4.5).
  - 노출은 servicelb다. svclb 출처 MASQUERADE 때문에 클라이언트들이 ratelimit 버킷 하나를 함께 쓰는지 확인한다. 함께 쓰면 `ratelimit_whitelist`나 hostNetwork로 바꾼다. hostNetwork는 노드 네임스페이스 공격면을 늘린다(PSA 예외가 필요하고, 침해되면 노드의 `127.0.0.1` 서비스와 모든 인터페이스에 닿는다, U32).
- 구성(설계 C.3.6): Deployment 1개, `Recreate`, PVC `local-retain` 1Gi, Service `LoadBalancer`(servicelb)로 `192.168.117.15:53` TCP·UDP. liveness 없음, readiness는 TCP 53. 관리 UI는 Tailscale Ingress로만. AdGuard Home v0.107.79를 이미지 digest로 고정한다. setcap 바이너리라 `allowPrivilegeEscalation: true` + `NET_BIND_SERVICE`만 주고, 빈 PVC에 파일을 만드는 컨테이너는 소비자와 같은 uid로 돈다.
- 시드: T06 내보내기에서 비밀과 LAN 기기 이름을 뺀 Git 시드다. 업스트림 DoH 2개, `upstream_mode: load_balance`, ratelimit 100 + 공유기 예외, `local_ptr_upstreams`, 필터 목록은 AdGuard DNS filter 하나, 사용자 규칙은 최소, 질의 로그 7일. 첫 부팅에만 복사한다(`cp -n`). 실행 중 설정 파일은 AdGuard가 다시 쓰므로, 라이브 UI 변경 중 남길 것은 시드로 옮긴다. 관리자 비밀번호 해시는 ESO Secret에서 init이 주입한다. rewrite는 두지 않는다.
- 질의 로그의 출처 표시(U32)는 T08b의 AdGuard tailnet 이탈 감시 방식을 정하는 입력이다. "tailnet 출처 질의 1시간 0건" 경보와 그 발화 시험은 T08b가 한다.

### cert-manager (`platform/cert-manager`)

- 클러스터 안 인증서만 낸다(Barman plugin TLS, T11이 쓴다). DNS-01용 Cloudflare 토큰은 두지 않는다. 버전은 이 티켓 시작 때 정해 고정한다(U14).

### R2 백업 버킷 (`infra/cloudflare`)

- 백업용 R2 버킷은 `homelab-backups` 하나, 보존은 PostgreSQL·Valkey 14일이다. 확정(사용자 2026-10-18, T05). 옛 버킷 3개는 T06이 지웠다.
- lifecycle은 prefix를 반드시 적는다(`prefix = ""`는 버킷 전체 만료). 영속 Valkey는 R2 lifecycle(prefix `valkey/`, 14일)로 지운다. PostgreSQL 14일은 CNPG ObjectStore `retentionPolicy`라 T11이 둔다.
- 버킷 전용 Object Read & Write 토큰 발급과 Infisical `/platform/backup` 등록은 T11의 사람 작업이다. 시나리오 13의 VM 전용 버킷은 T13이 만든다.

### Terraform root와 state 잠금 (D-28)

- root 셋을 R2 `homelab-tfstate`의 새 키 접두 `v2/`에 둔다: `infra/cloudflare`(`v2/cloudflare/terraform.tfstate`, provider v5 `>= 5.8.2`), `infra/tailscale`(`v2/tailscale/terraform.tfstate`), `infra/tailscale-dns`(`v2/tailscale-dns/terraform.tfstate`). 옛 키(`<root>/prod/terraform.tfstate`)를 쓰면 옛 state를 물려받아 plan이 옛 자원 삭제를 제안하므로 쓰지 않는다.
- 잠금은 S3 backend `use_lockfile = true`다. backend 자격은 환경변수로만 넣고, 공개해도 되는 endpoint만 `-backend-config`로 넣는다(backend 값은 `.terraform`과 plan 파일에 남는다).
- Terraform 자격: R2 state 키는 Infisical `homelab-admin`의 `/terraform/state`, provider 자격은 `/terraform/cloudflare`·`/terraform/tailscale`에 둔다. 실행은 `infisical run --path=/terraform/state -- infisical run --path=<provider 경로> -- terraform ...`처럼 두 번 겹친다(provider 경로는 `/terraform/cloudflare` 또는 `/terraform/tailscale`. `infra/tailscale-dns`도 `/terraform/tailscale`을 쓴다, 설계 C.3.9 표). 두 경로의 이름이 겹치지 않게 둔다. 겹친 실행이 바깥 경로의 R2 키를 넘기는지 첫 apply에서 확인한다(U02). 안 되면 root마다 R2 키를 provider 경로에 함께 둔다.
- Terraform state 잠금 (D-28). 첫 Terraform root를 apply하는 이 티켓에서 R2 `use_lockfile` 동시 실행 시험을 한 번 한다. U02는 R2 PutObject의 If-None-Match 원자성과 S3 backend lockfile 구현으로 문서·소스상 확인됐고 이 시험만 남았다. T10의 `infra/github` 첫 apply는 이 시험 뒤에 한다(설계 E.0).

## 필요한 자격

| 자격 | 위치 | 쓰는 곳 | 준비하는 티켓 |
|---|---|---|---|
| R2 state 버킷 키 | Infisical `homelab-admin` `/terraform/state` | 세 root의 backend | T09 |
| Cloudflare Terraform용 토큰 | `homelab-admin` `/terraform/cloudflare` | `infra/cloudflare` | T09 |
| Tailscale Terraform용 OAuth(ACL과 DNS 쓰기, 기기 읽기)와 기대 소유자 변수 | `homelab-admin` `/terraform/tailscale` | `infra/tailscale`, `infra/tailscale-dns` | OAuth는 T09. 기대 소유자 변수의 등록 담당은 설계에 없다 [미검증] |
| Tailscale operator OAuth client(Services·Devices Core·Auth Keys write, `tag:k8s-operator`) | Infisical `homelab` `/platform/tailscale` → ESO | `platform/tailscale` | 이 티켓(사람 발급) |
| 터널 토큰 | `homelab`의 플랫폼 경로(설계 C.2 `/platform/<구성 요소>`) → ESO | `platform/cloudflared` | 이 티켓(Terraform이 만든 터널의 토큰을 사람이 등록) |
| AdGuard 관리자 자격 | `homelab` → ESO(init이 해시 주입) | `platform/adguard` | T09 |

- Terraform 자격은 machine identity가 없는 `homelab-admin`에만 있어 ESO identity가 읽지 못한다. 클러스터에는 Cloudflare API 토큰을 두지 않는다.
- 콘솔 작업(사람): Cloudflare, Tailscale(HTTPS 인증서 켜기, NUC 키 만료 해제 확인, ACL 적용 전 정책 사본, DNS 현재 값 기록). GitHub 저장소 관리자 권한으로 시험 webhook 하나를 걸고 지운다. 시험 수신기와 시험 webhook이 함께 쓸 HMAC 비밀의 보관 위치는 설계에 없다.
- 시나리오 14는 NUC sudo(`sudo k3s crictl pull`)와 집 Wi-Fi·셀룰러의 Tailscale 기기가 필요하다.
- 백업 버킷 토큰은 이 티켓이 쓰지 않는다(T11).

## 제약

- 외부 변경(터널, DNS, 버킷, Tailscale 설정)은 사람 승인 뒤에 하고 [../approvals.md](../approvals.md)에 기록한다 (AC-X2).
- Tailscale 전역 DNS의 임시 Cloudflare 항목(C-05)은 D-08대로 지우고 AdGuard 공용 DNS 2개를 넣는다. 바꾸기 전에 콘솔 값을 옮겨 새 state에 import한 Terraform plan이 무변경인지 확인한다.
- 옛 `infra/tailscale` root는 apply도 destroy도 하지 않는다 (명세 §10의 12).
- 공개 저장소다. tailnet 이름, Tailscale IP, 소유자 값, 토큰은 HCL·문서·작업 기록에 쓰지 않는다.

## 완료 조건

- 시나리오 14(DNS)를 통과한다. D-08 추가 확인 둘이 들어간다: 셀룰러 Tailscale 기기 확인(AdGuard 정지 중 광고 도메인 차단, 일반 도메인 정상), 사용자 규칙 적용률 측정(AdGuard Home 전용 시험 차단 규칙을 집 Wi-Fi·셀룰러에서 20회씩, 결과 기록. 시험 이름은 공용 DNS에서 정상 주소가 나오는 `adg-<날짜>-<회차>.ukyi.app`이고 `0.0.0.0` 응답만 차단으로 센다, 설계 G 시나리오 14). LAN 기기 쪽은 설계 C.3.6의 AC-P6 판정 기준(확정(사용자 2026-10-18, T05): AdGuard를 멈춘 5분 동안 10초 간격 30회 질의, 실패 0회, 질의마다 응답 5초 이하)으로 판정한다. 못 미치면 시나리오 14를 실패로 기록하고, 사용자가 한계로 승인하거나 F D-08을 다시 본다.
- Tailscale DNS가 (b′)이고 DNS plan이 무변경이다.
- 공개 시험 URL이 200, 없는 host가 404, cloudflared `/ready`가 200이다.
- 내부 UI가 `*.ts.net`으로 열린다.
- 새 ACL 적용 뒤 원격에서 NUC로 Tailscale SSH가 된다.
- 설계 C.8의 공개 webhook 경로 준비 확인을 통과한다.
- R2 잠금 동시 실행 시험(U02)을 한 번 했고 결과가 기록돼 있다. T10의 `infra/github` 첫 apply가 이것을 기다린다.

## 검증

- 공개 경로: `curl -sI https://<시험 host>.ukyi.app` → 200, `curl -sI https://nope.ukyi.app` → 404, cloudflared `/ready` → 200.
- 내부 UI: tailnet 기기에서 `curl -sI https://argocd.<tailnet>.ts.net` → 200 또는 로그인 리다이렉트. tailnet 밖에서는 이름이 풀리지 않는다. operator Ingress의 `status.loadBalancer.ingress[0].hostname`이 `*.ts.net`이다.
- 새 ACL을 적용한 뒤 원격에서 NUC로 Tailscale SSH 접속이 되는지 확인한다(`tailscale ssh <NUC>`).
- Tailscale DNS root에 콘솔 값을 옮겨 import한 뒤 첫 plan이 무변경인지 확인한다. (b′) apply 뒤 `tailscale dns status --all`에 nameserver 셋(NUC, AdGuard 공용 2개)이 있고 Cloudflare가 없다.
- `dig @192.168.117.15 example.com +short` → 응답.
- AdGuard를 멈추고 LAN 기기, Tailscale 기기(집 Wi-Fi와 셀룰러), 노드 자신의 이름 해석을 각각 확인한다. Tailscale 기기에서는 광고 도메인이 차단되고 일반 도메인이 풀리는지 본다. 멈추기는 `platform/adguard` replicas 0 PR 병합으로 한다(selfHeal이 되돌리지 않게). 세부 명령은 설계 G 시나리오 14다:
  - LAN 기기에서 10초 간격 30회, 매번 고유 이름으로 `dig "am$(date +%s)-$i.example.com" +tries=1 +time=5`의 이름·`status`·`Query time`과 실패 수(시간 초과·SERVFAIL·REFUSED)를 기록한다(U19).
  - 셀룰러의 Tailscale 기기에서 `nslookup doubleclick.net` → 차단 응답(`0.0.0.0` 또는 NXDOMAIN), `nslookup example.com` → 정상(U33).
  - 노드에서 `resolvectl query example.com`, `sudo k3s crictl pull docker.io/library/busybox:1.37`. tailnet 기기에서 `curl -sI https://argocd.<tailnet>.ts.net`.
  - revert PR 뒤 차단 도메인이 다시 차단되고, 같은 기기의 질의가 AdGuard Home 질의 로그에 찍히는지와 그 출처 표시를 기록한다(U32).
- 규칙을 넣기 전에 시험 이름(`adg-<날짜>-<회차>.ukyi.app`)이 두 경로 모두 정상 주소로 풀리는지 본다. 그다음 AdGuard Home에만 있는 시험 차단 규칙(예: `||adg-<날짜>-*.ukyi.app^`)으로 집 Wi-Fi와 셀룰러의 Tailscale 기기에서 20회씩 조회해 `0.0.0.0` 응답 수를 기록하고 AdGuard Home 질의 로그와 대조한 뒤 규칙을 지운다. 없는 이름은 공용 서버도 NXDOMAIN이라 차단으로 잘못 세므로 쓰지 않는다.
- svclb를 거친 질의의 출처 주소와 ratelimit 버킷 공유 여부를 확인한다(U32).
- 같은 state로 Terraform을 동시에 두 번 실행해 하나가 잠금으로 멈추는지 확인한다(U02: 같은 root를 두 터미널에서 동시에 plan).
- 공개 webhook 경로(설계 C.8): `curl -s -o /dev/null -w '%{http_code}' https://hooks.ukyi.app/github`(GET) → 403, 다른 경로 POST → 403(또는 404), 서명이 틀린 POST → 401, 한 저장소에 시험 webhook을 걸고 ping 전송 → Recent Deliveries 200.
- U28: 새 ACL 적용 뒤 NetworkPolicy가 없는 시험 ns의 파드에서 운영자 노트북의 시험 포트로 연결해 성공 여부와 받은 쪽의 출발 주소만 기록한다. 결과는 D-11 (c) 재검토의 입력이다.
- 노드 DNS: `resolvectl status`에 `1.1.1.1 9.9.9.9`, `tailscale dns status` → "Tailscale DNS: disabled".
- cert-manager: `kubectl -n cert-manager get deploy` Ready, 시험 Certificate Ready.
- R2: `homelab-backups`의 lifecycle 규칙에 prefix `valkey/`가 적혀 있다.

## 되돌리는 방법

- Tailscale ACL은 적용 전 정책 사본을 남기고, 그 사본으로 되돌린다.
- Tailscale DNS는 C-05 값을 선언한 커밋으로 되돌려 apply한다. 급하면 콘솔에서 Cloudflare 항목을 다시 넣고 HCL을 맞춘다. 이 root는 `prevent_destroy`라 destroy로 되돌리지 않는다.
- Terraform은 새 state라 새 자원만 `terraform destroy -target`으로 지울 수 있다(옛 자원 없음).
- 클러스터 쪽(`platform/*`)은 revert PR로 되돌린다.
- 되돌리기 실행도 [../approvals.md](../approvals.md)에 기록한다.
