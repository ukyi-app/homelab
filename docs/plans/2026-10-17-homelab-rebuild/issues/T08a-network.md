# T08a 네트워크·DNS·외부 공개

- 단계: P2 플랫폼 구축 (재분해 T05 2026-10-18)
- 상태: 완료 (2026-10-21. 2026-10-20 착수. 결과는 아래 "결과". AC-P6 LAN 불합격은 사용자 한계 승인)
- 명세: [../spec.md](../spec.md) §4.5
- 설계: [../platform/design.md](../platform/design.md) E.1 E4a, E.3, C.3.4~C.3.6, C.3.8, C.3.9, C.8
- Blocked by: T07, T09
- 선행 결정: D-08 (확정(사용자 2026-10-18): 내부 UI `*.ts.net`, Tailscale DNS (b′)), D-11 (확정(사용자 2026-10-18, T05): 설계 F D-11 표 그대로. Tailscale ACL은 2026-10-20 U28 결과로 (c)(NUC `tag:nuc`, NUC → 사람 기기 규칙 없음)로 바뀜(사용자))), D-12 (확정(사용자 2026-10-18, T05): 노드 DNS drop-in은 T06이 남기고 T07이 덮어씀), D-28 (확정(사용자 2026-10-18): Terraform state 잠금 시험), 공개 DNS 방식·Argo CD 공개 webhook·백업 보존 (확정(사용자 2026-10-18, T05): 설계 F "추가 확인")
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

### Tailscale ACL (D-11 (c), `infra/tailscale`)

- 2026-10-20 16:30에 (a) 정책(태그 없는 NUC, self 규칙)을 적용했다. 같은 날 U28 결과로 D-11이 (c)로 바뀌었다(사용자). (c)는 2026-10-21에 아래 순서로 적용했다(결과).
- **ACL PR 하나에 넣을 것(설계 C.3.5 예시):** tagOwners `tag:nuc`·`tag:k8s-go`, 공유기 경로 `autoApprovers`, `autogroup:owner`·`autogroup:admin` → `tag:nuc:22,6443`(mosh를 쓰면 그 UDP 범위도), `autogroup:member → tag:nuc:53`, `autogroup:member`·`tag:nuc` → `tag:k8s:443`, `autogroup:member → tag:k8s-go:80`(T08c), 공유기 관리 화면 grant(사용자가 콘솔에 넣은 것을 옮김. 지금 `infra/tailscale` plan은 이 grant를 지우는 드리프트라 그 전에는 apply하지 않는다), ssh `autogroup:owner`·`autogroup:admin` → `tag:nuc`(`accept`, nonroot + root. 태그 대상은 self처럼 소유자로 좁혀지지 않아 src를 운영자로 둔다. Owner는 `autogroup:admin`에 들지 않으므로 둘 다 적는다). ACL apply가 정책 오류로 거부되면 태그를 붙이지 않고 멈춘다. NUC → 사람 기기 규칙은 두지 않는다. self 규칙은 사람 기기끼리 쓰려고 남긴다.
- **같은 PR:** `infra/tailscale-dns`의 precondition을 "기대 소유자의 태그 없는 기기"에서 "태그가 `tag:nuc` 하나"로 바꾸고 `nuc_expected_owner` 변수와 Infisical 키를 정리한다. `docs/runbooks-public/bootstrap.md`의 NUC 등록에 `--advertise-tags=tag:nuc`와 `--advertise-routes=192.168.117.1/32`를 넣고 키 만료 해제 단계를 확인으로 바꾼다(`autoApprovers`는 광고된 경로를 승인할 뿐 광고하지 않는다).
- **적용 순서(집에서, LAN으로 NUC에 닿을 수 있을 때):** (0) NUC가 공유기 경로를 광고하는지 본다(`tailscale debug prefs`의 `AdvertiseRoutes`. 2026-10-20에는 광고 중). 없으면 `sudo tailscale set --advertise-routes=192.168.117.1/32` → (1) 정책 사본을 저장소 밖에 둔다 → (2) ACL plan·apply. 새 규칙이 먼저 생기고 NUC는 아직 사용자 기기라 기존 경로가 그대로다(네트워크 self 규칙과 ssh self 규칙을 둘 다 남겨야 한다. SSH는 네트워크 규칙과 ssh 규칙이 모두 필요하다) → (3) 콘솔에서 NUC에 `tag:nuc`를 붙인다 → (4) 원격 기기에서 SSH(tailnet 주소의 sshd), kubectl, AdGuard DNS(`dig @<NUC tailnet 주소>`), 공유기 관리 화면, 내부 UI를 확인한다 → (5) `infra/tailscale-dns` plan·apply(값 무변경, precondition 통과) → (6) U28 재시험: 같은 시험 파드가 운영자 기기에 닿지 않아야 한다.
- **되돌리기:** 정책 사본으로 ACL을 되돌리고, NUC를 사용자 기기로 다시 로그인한 뒤 키 만료를 끈다. `tailscale up`은 실행마다 바꾼 플래그를 모두 다시 줘야 하므로 전체로 적는다: `sudo tailscale up --force-reauth --hostname=<NODE_NAME> --accept-dns=false --advertise-routes=192.168.117.1/32 --advertise-tags=`(빈 값이 태그 제거). 브라우저 로그인이 필요하다.
- D-08 (b′)에서 운영자 기기가 NUC의 AdGuard Home(`:53`)에 닿는 길은 `autogroup:member → tag:nuc:53`이다. 빠뜨려도 공용 서버가 답해 증상이 없으므로 적용 뒤 AdGuard 질의 로그로 본다.
- 남는 위험: 사람 기기를 잃으면 그 기기에 있는 SSH 키로 비root 계정에 들어온다. NUC는 Tailscale SSH를 켜지 않아(사용자 2026-10-21) ACL의 ssh 규칙(root 포함)은 쓰이지 않고, sshd는 root 로그인을 막는다.

### Tailscale DNS (D-08, `infra/tailscale-dns`)

- 목표 값: Override local DNS 켬, 전역 nameserver = [NUC Tailscale IP(AdGuard Home), `94.140.14.14`, `94.140.15.15`](AdGuard 공용 DNS, AdGuard Home 기본값과 같은 AdGuard DNS filter), C-05의 임시 Cloudflare 4개 삭제, MagicDNS 켬, HTTPS 켬, `use_with_exit_node` 기본 끔. 목적은 Tailscale을 켠 기기가 집 안팎 어디서든 차단을 받고, NUC 장애 때도 공용 서버가 차단하며 답하는 것이다. 대가 다섯은 명세 §4.5 "Tailscale DNS"에 있다.
- Terraform `tailscale_dns_configuration`(provider v0.29.2, 정식)으로 관리한다. `data.tailscale_devices`로 hostname이 일치하는 기기를 받아 precondition을 건다: 정확히 1대, 태그 `tag:nuc` 하나(D-11 (c). 태그 기기는 사용자 소유가 아니라 소유자 검사를 두지 않는다), `key_expiry_disabled`. (c) 적용 전 지금 코드는 기대 소유자의 태그 없는 기기를 검사하므로 (c) 적용 PR에서 바꾼다. IPv4는 `100.` 대역으로 골라낸다. `tailscale_dns_nameservers`와 함께 쓰지 않는다. 기대 소유자 값은 공개 HCL에 쓰지 않고 변수(`homelab-admin`의 `/terraform/tailscale`)로 받는다(D-23).
- 이 자원은 DNS 설정 전체를 소유한다. 첫 apply 전에 콘솔의 현재 값을 기록하고, 그 값을 그대로 옮긴 HCL로 새 state에 import한 뒤(import 블록, provider가 지원) plan 무변경을 확인하고 목표 값으로 바꾼다. import 없이 새 state로 plan하면 생성 계획이 나온다. 선언하지 않은 콘솔 값(nameserver, split DNS, search path)은 첫 apply에서 지워지고, `override_local_dns`를 빠뜨리면 기본 false라 기기가 로컬 DNS를 계속 쓴다(plan은 정상).
- DNS는 ACL과 나눈 별도 root `infra/tailscale-dns`(state 키 `v2/tailscale-dns/terraform.tfstate`)에 두고 리소스에 `prevent_destroy`를 건다. NUC가 없을 때 precondition 오류가 ACL apply까지 막지 않게 하려는 것이다. 조건부(`count`)는 쓰지 않는다. NUC가 없는 동안 apply가 DNS 설정 전체의 삭제를 계획해 공용 폴백과 Override까지 사라지기 때문이다. NUC가 tailnet에 없는 동안은 이 root를 apply하지 않는다. Override를 켠 상태에서 AdGuard가 죽어도 공용 서버가 답하므로 Terraform 실행 기기의 DNS 문제는 작다.
- NUC를 Tailscale에 다시 등록하면 키 만료가 기본값(켜짐)으로 돌아오고 Tailscale IP가 바뀔 수 있다. 키 만료를 해제한 뒤 apply하면 data source가 새 IP를 쓴다. 만료가 켜진 채면 precondition이 apply를 멈춘다.
- 이 HCL과 import는 [미검증] U34다(문서·소스로만 맞춰 썼다). 안 되면 콘솔에서 한 번 설정하고 `bootstrap.md`에 값의 출처와 확인 명령(`tailscale dns status --all`)을 적는 방식으로 돌아간다(IaC 밖, 드리프트는 사람 확인).

### AdGuard와 노드 DNS (`platform/adguard`)

- AdGuard. 같은 LAN IP `192.168.117.15`의 `:53`으로 서빙해 공유기 설정을 그대로 쓴다. 노드 자신의 DNS에는 함정이 두 개 있다.
  - Tailscale 쪽: k3s 노드 자신은 tailnet 전역 nameserver를 받지 않게 한다.
  - LAN 쪽: 공유기의 주 DNS가 노드 위 AdGuard라서, 노드가 DHCP DNS를 쓰면 "노드 → 공유기 → 노드 위 AdGuard" 순환이 생긴다. 콜드스타트 때 AdGuard가 아직 없으면 이름 해석이 막히고 이미지 pull까지 막힌다.
  - 막는 법: 노드는 공용 DNS를 직접 쓴다. 옛 host-config의 resolved drop-in과 `tailscale set --accept-dns=false`가 하던 일이다. D-12 확정(사용자 2026-10-18, T05)대로 T06이 이 drop-in(H5)을 남겼고 T07이 Git의 호스트 설정으로 덮어썼다. 이 티켓은 그 설정이 있는지 확인한다(`resolvectl status`에 `1.1.1.1 9.9.9.9`, `tailscale dns status` → "Tailscale DNS: disabled", 명세 §4.5).
  - 노출은 servicelb다. svclb 출처 MASQUERADE 때문에 클라이언트들이 ratelimit 버킷 하나를 함께 쓰는지 확인한다. 함께 쓰면 `ratelimit_whitelist`나 hostNetwork로 바꾼다. 2026-10-21 확인: 함께 쓴다. ratelimit을 껐다(사용자, 결과). hostNetwork는 노드 네임스페이스 공격면을 늘린다(PSA 예외가 필요하고, 침해되면 노드의 `127.0.0.1` 서비스와 모든 인터페이스에 닿는다, U32).
- 구성(설계 C.3.6): Deployment 1개, `Recreate`, PVC `local-retain` 1Gi, Service `LoadBalancer`(servicelb)로 `192.168.117.15:53` TCP·UDP. liveness 없음, readiness는 TCP 53. 관리 UI는 Tailscale Ingress로만. AdGuard Home v0.107.79를 이미지 digest로 고정한다. setcap 바이너리라 `allowPrivilegeEscalation: true` + `NET_BIND_SERVICE`만 주고, 빈 PVC에 파일을 만드는 컨테이너는 소비자와 같은 uid로 돈다.
- 시드: T06 내보내기에서 비밀과 LAN 기기 이름을 뺀 Git 시드다. 업스트림 DoH 2개, `upstream_mode: load_balance`, ratelimit 끔(U32), `local_ptr_upstreams`, 필터 목록은 AdGuard DNS filter 하나, 사용자 규칙은 최소, 질의 로그 7일. 첫 부팅에만 복사한다(`cp -n`). 실행 중 설정 파일은 AdGuard가 다시 쓰므로, 라이브 UI 변경 중 남길 것은 시드로 옮긴다. 관리자 비밀번호 해시는 ESO Secret에서 init이 주입한다. rewrite는 두지 않는다.
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
- (c) ACL과 NUC 태그를 적용한 뒤 원격에서 NUC로 SSH(tailnet 주소의 sshd)·kubectl·AdGuard DNS·공유기 관리 화면이 되고, U28 재시험에서 시험 파드가 운영자 기기에 닿지 않는다.
- 설계 C.8의 공개 webhook 경로 준비 확인을 통과한다.
- R2 잠금 동시 실행 시험(U02)을 한 번 했고 결과가 기록돼 있다. T10의 `infra/github` 첫 apply가 이것을 기다린다.

## 검증

- 공개 경로: `curl -sI https://<시험 host>.ukyi.app` → 200, `curl -sI https://nope.ukyi.app` → 404, cloudflared `/ready` → 200.
- 내부 UI: tailnet 기기에서 `curl -sI https://argocd.<tailnet>.ts.net` → 200 또는 로그인 리다이렉트. tailnet 밖에서는 이름이 풀리지 않는다. operator Ingress의 `status.loadBalancer.ingress[0].hostname`이 `*.ts.net`이다.
- 새 ACL을 적용한 뒤 원격에서 NUC tailnet 주소로 SSH(sshd, 키 인증) 접속이 되는지 확인한다(`ssh <NUC>`). NUC는 Tailscale SSH를 켜지 않는다(사용자 2026-10-21).
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
- U28: NetworkPolicy가 없는 시험 ns의 파드에서 운영자 기기의 시험 포트로 연결해 성공 여부와 출발 주소를 기록한다. (a)에서는 2026-10-20에 성공했고 출발 주소가 NUC의 Tailscale 주소였다(그래서 (c)). **(c) 적용 뒤 재시험의 기대 결과는 연결 실패다.** 성공하면 (c) 규칙을 다시 본다.
- 노드 DNS: `resolvectl status`에 `1.1.1.1 9.9.9.9`, `tailscale dns status` → "Tailscale DNS: disabled".
- cert-manager: `kubectl -n cert-manager get deploy` Ready, 시험 Certificate Ready.
- R2: `homelab-backups`의 lifecycle 규칙에 prefix `valkey/`가 적혀 있다.

## 결과 (2026-10-20~21)

실제 IP·tailnet 이름은 적지 않는다(D-23). 시각과 명령의 세부는 [../approvals.md](../approvals.md).

- 공개 경로: `edge-probe.ukyi.app` 200, 없는 host 404, cloudflared 커넥터 4개, HSTS 헤더. **U01 통과**(원격 관리 터널이 와일드카드 hostname을 받음).
- 공개 webhook 경로: `hooks.ukyi.app/github` GET 403, 다른 경로 POST 403, 틀린 서명 401, `ukyi-app/homelab` 시험 webhook ping 200(생성 뒤 바로 삭제). **AC-P12 이 자리 통과.**
- 내부 UI: Argo CD·AdGuard가 tailnet 주소로 유효 인증서와 함께 열림. Tailscale IPv4를 바꾼 뒤에도 그대로 열림.
- ACL: 새 정책 import·적용, 원격 기기에서 `tailscale ssh`로 NUC 접속(사람 확인).
- Tailscale DNS: adopt import 무변경 → (b′) 목표 전환 apply, 직후 plan 무변경. 전역 nameserver = NUC 현재 IPv4 + `94.140.14.14` + `94.140.15.15`, Cloudflare 없음. **U34의 import·DNS 동작 통과**(provider는 Alpha Resource 경고. (a)의 소유자 precondition으로 실행했다). 2026-10-21 (c) 적용 뒤 `tag:nuc` precondition으로 plan 무변경(**U34 통과**, 값이 같아 apply는 하지 않음).
- AdGuard: LAN·tailnet 주소 모두 응답, 기본 목록 차단(`doubleclick.net` → `0.0.0.0`).
- 시나리오 14:
  - LAN(공유기 경유, 10초 간격 30회): 26회 시간 초과, 복구 뒤 4회 정상. **AC-P6 LAN 불합격, 사용자 한계 승인.** NUC 무응답 시험(nft DROP 150초)에서도 11회 모두 시간 초과라 공유기가 보조 DNS로 넘어가지 않는다(**U19**). 이 공유기는 DHCP DNS 지정과 DNS 프록시 끄기가 없다. 완화: 런북 `docs/runbooks-public/nuc-dns-outage.md`, T08b AdGuard 정지 경보.
  - 셀룰러 Tailscale 기기(NUC AdGuard 무응답 중): `doubleclick.net` → `0.0.0.0`, `example.com` 정상. **U33 통과.**
  - 노드: `resolvectl query example.com` 정상(AdGuard 정지 중). 이미지 받기는 정지 중 sudo 시간 초과로 못 해서, 19:25에 노드와 파드에서 NUC AdGuard(LAN·tailnet 주소 `:53`)로 가는 길만 막은 상태(LAN·tailnet 기기 영향 없음)에서 캐시 안 된 `busybox:1.36`을 받았다(성공). 노드는 AdGuard 없이 동작한다.
  - 내부 UI: AdGuard 정지 중 NUC에서 Argo CD HTTPS 200.
  - 사용자 규칙 적용률: 셀룰러 19/20, 집 Wi-Fi 20/20(2026-10-21, 맥이 집 LAN + Tailscale, `@100.100.100.100`). 시험 규칙은 사용자가 지웠다.
- U02: 같은 root 동시 plan에서 하나가 `Error acquiring the state lock`(통과).
- U28: NetworkPolicy 없는 시험 ns 파드가 운영자 맥의 Tailscale 주소 시험 포트에 연결 성공. 19:25 NUC `tailscale0` tcpdump에서 그 SYN의 출발 주소가 NUC의 Tailscale 주소였다(SNAT). 이 결과로 D-11을 (c)로 바꿨다(사용자). 2026-10-21 (c) 적용 뒤 재시험: 시험 파드 → 운영자 맥 시험 포트 3회 모두 실패, NUC 호스트에서도 실패. 대조로 같은 파드 → 인터넷과 다른 맥 → 그 시험 포트는 성공(**U28 해결**).
- D-11 (c) 적용(2026-10-21, 집): (0) NUC가 `192.168.117.1/32`를 광고 중, `ip_forward` 1(k3s가 런타임에 켬. 지속 drop-in은 새로 설치할 때 `bootstrap.md`가 둔다) → (1) 정책 사본을 저장소 밖에 둠 → (2) #787 병합, `infra/tailscale` apply(1 changed, 공유기 grant 유지) → (3) 콘솔에서 NUC에 `tag:nuc`(소유가 태그로, 키 만료 꺼짐. 열린 SSH 세션 유지) → (4) 집 밖 맥에서 NUC tailnet 주소 22·6443 열림, 새 SSH 로그인 성공, AdGuard DNS 차단·정상, 공유기 관리 화면(Tailscale 경로) 200, Argo CD 200·AdGuard 302. NUC → `tag:k8s:443`도 됨(NUC는 tailnet DNS를 받지 않아 이름은 직접 지정) → (5) `infra/tailscale-dns` plan 무변경 → (6) U28 재시험 실패(위) → (7) 쓰지 않는 Infisical 키 `TF_VAR_nuc_expected_owner` 삭제(사람).
  - NUC에서 사람 기기로 가는 tailnet 연결도 모두 막힌다(예: NUC에서 맥으로 ssh). LAN 주소로는 된다.
  - NUC의 Tailscale SSH는 꺼져 있다(`tailscale debug prefs`의 `RunSSH` false. 2026-10-19에는 켜져 있었고 언제 꺼졌는지는 모른다). 원격 SSH는 tailnet 주소의 sshd(키 인증, root 로그인 금지)이고 ACL의 22 규칙이 그 길을 연다. 사용자가 끈 채로 두기로 했다(2026-10-21 "1번으로 해"). 그래서 `tag:nuc` 대상 ssh 규칙은 쓰이지 않고, `bootstrap.md`의 등록 명령에서 `--ssh`를 뺐다.
- U32(2026-10-21, AdGuard `querylog.json`): 공유기 경유 질의(`adg-20261020-lan1`)는 `10.42.0.1`(노드 cni0), NUC tailnet 주소로 보낸 질의(`-tsn1`, 셀룰러 20회 포함)는 svclb 파드 IP로 보인다. 로그 전체의 출처도 이 둘뿐이다. 둘이 같은 /24라 `ratelimit: 100`, `ratelimit_subnet_len_ipv4: 24`에서 집 LAN과 tailnet 전체가 버킷 하나를 쓰고, 공유기 주소 예외(`192.168.117.1`)는 맞지 않는다. 약 9.5시간 로그에 초당 100건 이상인 초가 셋(tailnet 출처 100건 둘, LAN 출처 198건 하나)이고, 50건 이상인 초가 24개다. 제한에 걸려 버려진 질의가 있었는지는 로그로 확인하지 못했다. **ratelimit을 껐다**(사용자 2026-10-21 "1번으로 진행하자": 시드 `ratelimit: 0`, 라이브 설정은 관리 화면에서 사람이 바꿈. 파드 IP 예외는 재시작마다 바뀌어, hostNetwork는 PSA 예외와 공격면 때문에 제외). T08b 이탈 감시는 `10.42.0.1`이 아닌 출처를 tailnet 질의로 센다.
- 노드 DNS: `resolvectl` 전역 `1.1.1.1 9.9.9.9`, `tailscale dns status` "Tailscale DNS: disabled."
- cert-manager: 세 Deployment Ready, 시험 ns의 selfSigned Certificate Ready(ns 삭제).
- R2: `homelab-backups` lifecycle prefix `valkey/`, 14일, 켜짐. Cloudflare plan 드리프트 없음.

### 부록: 시나리오 14 원자료

NUC에서 공유기(LAN 기기가 쓰는 DNS)로 물었다. 매번 처음 묻는 이름, `dig +tries=1 +time=5`, 질의 사이 10초 대기다(시간 초과 때 실제 간격은 15초). 줄 형식은 `시각 회차 이름 상태 응답시간`이다. AdGuard 정지는 18:13:12~18:19:47이라 27~30회는 복구 뒤다.

```text
# start 2026-10-20 18:13:26 router=192.168.117.1
18:13:31 1 am1792487606-1.example.com TIMEOUT -ms
18:13:46 2 am1792487621-2.example.com TIMEOUT -ms
18:14:01 3 am1792487636-3.example.com TIMEOUT -ms
18:14:16 4 am1792487651-4.example.com TIMEOUT -ms
18:14:31 5 am1792487666-5.example.com TIMEOUT -ms
18:14:46 6 am1792487681-6.example.com TIMEOUT -ms
18:15:01 7 am1792487696-7.example.com TIMEOUT -ms
18:15:16 8 am1792487711-8.example.com TIMEOUT -ms
18:15:31 9 am1792487726-9.example.com TIMEOUT -ms
18:15:46 10 am1792487741-10.example.com TIMEOUT -ms
18:16:01 11 am1792487756-11.example.com TIMEOUT -ms
18:16:16 12 am1792487771-12.example.com TIMEOUT -ms
18:16:31 13 am1792487786-13.example.com TIMEOUT -ms
18:16:46 14 am1792487801-14.example.com TIMEOUT -ms
18:17:01 15 am1792487816-15.example.com TIMEOUT -ms
18:17:16 16 am1792487831-16.example.com TIMEOUT -ms
18:17:31 17 am1792487846-17.example.com TIMEOUT -ms
18:17:46 18 am1792487861-18.example.com TIMEOUT -ms
18:18:01 19 am1792487876-19.example.com TIMEOUT -ms
18:18:17 20 am1792487891-20.example.com TIMEOUT -ms
18:18:32 21 am1792487907-21.example.com TIMEOUT -ms
18:18:47 22 am1792487922-22.example.com TIMEOUT -ms
18:19:02 23 am1792487937-23.example.com TIMEOUT -ms
18:19:17 24 am1792487952-24.example.com TIMEOUT -ms
18:19:32 25 am1792487967-25.example.com TIMEOUT -ms
18:19:47 26 am1792487982-26.example.com TIMEOUT -ms
18:19:57 27 am1792487997-27.example.com NOERROR 46ms
18:20:07 28 am1792488007-28.example.com NOERROR 14ms
18:20:17 29 am1792488017-29.example.com NOERROR 13ms
18:20:27 30 am1792488027-30.example.com NOERROR 46ms
# end 2026-10-20 18:20:27 fail=26 slow_over_5s=0
```

NUC 무응답 시험(nft DROP 18:52:39~18:55:09). 이 측정은 이름을 기록하지 않았다(이름 꼴 `ad<epoch>-<회차>.example.com`).

```text
# start 2026-10-20 18:52:39 router=192.168.117.1 mode=nuc-silent
18:52:44 1 TIMEOUT -ms
18:52:59 2 TIMEOUT -ms
18:53:14 3 TIMEOUT -ms
18:53:29 4 TIMEOUT -ms
18:53:44 5 TIMEOUT -ms
18:53:59 6 TIMEOUT -ms
18:54:15 7 TIMEOUT -ms
18:54:30 8 TIMEOUT -ms
18:54:45 9 TIMEOUT -ms
18:55:00 10 TIMEOUT -ms
18:55:15 11 TIMEOUT -ms
18:55:25 12 NOERROR 12ms
# end 2026-10-20 18:55:25 fail=11
```

셀룰러 사용자 규칙 적용률(맥 핫스팟 + Tailscale, `@100.100.100.100`, 이름 `adg-20261020-c<회차>.ukyi.app`, 사용자 실행 결과).

```text
c01 0.0.0.0
c02 0.0.0.0
c03 0.0.0.0
c04 0.0.0.0
c05 0.0.0.0
c06 0.0.0.0
c07 0.0.0.0
c08 0.0.0.0
c09 0.0.0.0
c10 0.0.0.0
c11 0.0.0.0
c12 0.0.0.0
c13 0.0.0.0
c14 0.0.0.0
c15 104.21.55.203
c16 0.0.0.0
c17 0.0.0.0
c18 0.0.0.0
c19 0.0.0.0
c20 0.0.0.0
CELL_BLOCKED=19/20
```

## 되돌리는 방법

- Tailscale ACL은 적용 전 정책 사본을 남기고, 그 사본으로 되돌린다.
- Tailscale DNS는 C-05 값을 선언한 커밋으로 되돌려 apply한다. 급하면 콘솔에서 Cloudflare 항목을 다시 넣고 HCL을 맞춘다. 이 root는 `prevent_destroy`라 destroy로 되돌리지 않는다.
- Terraform은 새 state라 새 자원만 `terraform destroy -target`으로 지울 수 있다(옛 자원 없음).
- 클러스터 쪽(`platform/*`)은 revert PR로 되돌린다.
- 되돌리기 실행도 [../approvals.md](../approvals.md)에 기록한다.
