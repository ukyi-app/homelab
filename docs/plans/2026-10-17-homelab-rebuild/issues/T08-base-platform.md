# T08 기반 플랫폼

- 단계: P2 플랫폼 구축 (잠정)
- 상태: 대기
- 명세: [../spec.md](../spec.md) §4.2
- Blocked by: T07, T09
- 선행 결정: D-08 (확정(사용자 2026-10-18): 내부 UI `*.ts.net`, Tailscale DNS (b′)), D-09, D-10, D-11 (Tailscale ACL·DNS 덮어쓰기와 NUC `tag:nuc` 여부, zone 설정, healthchecks.io 체크), D-28 (확정(사용자 2026-10-18): Terraform state 잠금 시험)
- 연결 AC: AC-P6, AC-P11, AC-P12
- 수행: 에이전트 + 사람 (Cloudflare·Tailscale 콘솔, Terraform apply(owner 로컬), 토큰, 외부 감시·비AI 알림 채널 계정·토큰. 명세 §11)

## 목표

CI/CD와 앱이 올라갈 네트워크·DNS·관측·알림·백업을 세운다.

## 입력

- T06이 내보낸 옛 AdGuard 라이브 설정 (비밀값 제외).

## 범위

- Cloudflare 터널과 인그레스. 공개 webhook 수신 경로를 포함한다. `.app` 최상위 도메인 전체가 브라우저 HSTS preload 목록에 있어 `ukyi.app` 아래 모든 이름은 처음 접속하는 브라우저에서도 HTTPS 전용이다. 그래서 공개 이름은 처음부터 유효한 인증서의 HTTPS로 띄운다. 평문 HTTP나 자체 서명 인증서는 브라우저가 열어 주지 않는다. zone HSTS 헤더(includeSubDomains, 180일)는 이와 별개로 유지한다(D-11).
- 내부 UI (D-08). Tailscale operator Ingress의 `<서비스>.<tailnet>.ts.net`으로 띄운다(UI마다 단독 프록시). `*.home.ukyi.app` 내부 이름, AdGuard rewrite, 내부 와일드카드 인증서, cert-manager DNS-01 Cloudflare 토큰, traefik-ts는 두지 않는다. tailnet HTTPS 인증서를 켜면 기기 이름과 tailnet DNS 이름이 공개 CT 로그에 실리므로, 공개해도 되는 기기 이름만 쓴다.
- Tailscale operator와 DNS 설정 (D-08). 새 ACL은 `autogroup:self` 허용과 ssh 규칙을 유지한다. 빠지면 운영자의 NUC 원격 접속이 끊긴다.
  - 목표 값: Override local DNS 켬, 전역 nameserver = [NUC Tailscale IP(AdGuard Home), `94.140.14.14`, `94.140.15.15`](AdGuard 공용 DNS, AdGuard Home 기본값과 같은 AdGuard DNS filter), C-05의 임시 Cloudflare 4개 삭제, MagicDNS 켬, HTTPS 켬, `use_with_exit_node` 기본 끔. 목적은 Tailscale을 켠 기기가 집 안팎 어디서든 차단을 받고, NUC 장애 때도 공용 서버가 차단하며 답하는 것이다. 대가 다섯은 명세 §4.5 "Tailscale DNS"에 있다.
  - Terraform `tailscale_dns_configuration`(provider v0.29.2, 정식)으로 관리한다. `data.tailscale_devices`로 hostname이 일치하는 기기를 받아 precondition을 건다: 정확히 1대, 소유자·태그 기대값, `key_expiry_disabled`. IPv4는 `100.` 대역으로 골라낸다. `tailscale_dns_nameservers`와 함께 쓰지 않는다.
  - 이 자원은 DNS 설정 전체를 소유한다. 첫 apply 전에 콘솔의 현재 값을 기록하고, 그 값을 그대로 옮긴 HCL로 새 state에 import한 뒤(import 블록, provider가 지원) plan 무변경을 확인하고 목표 값으로 바꾼다. import 없이 새 state로 plan하면 생성 계획이 나온다.
  - DNS는 ACL과 나눈 별도 root `infra/tailscale-dns`(state 키 `v2/tailscale-dns/terraform.tfstate`)에 두고 리소스에 `prevent_destroy`를 건다. NUC가 없을 때 precondition 오류가 ACL apply까지 막지 않게 하려는 것이다. 조건부(`count`)는 쓰지 않는다. NUC가 없는 동안 apply가 DNS 설정 전체의 삭제를 계획해 공용 폴백과 Override까지 사라지기 때문이다. NUC가 tailnet에 없는 동안은 이 root를 apply하지 않는다. Override를 켠 상태에서 AdGuard가 죽어도 공용 서버가 답하므로 Terraform 실행 기기의 DNS 문제는 작다.
  - Terraform 자격: R2 state 키는 Infisical `homelab-admin`의 `/terraform/state`, provider 자격은 `/terraform/cloudflare`·`/terraform/tailscale`에 둔다. 실행은 `infisical run --path=/terraform/state -- infisical run --path=<provider 경로> -- terraform ...`처럼 두 번 겹친다(provider 경로는 `/terraform/cloudflare` 또는 `/terraform/tailscale`. `infra/tailscale-dns`도 `/terraform/tailscale`을 쓴다, 설계 C.3.9 표). 겹친 실행이 바깥 경로의 R2 키를 넘기는지 첫 apply에서 확인한다(U02).
  - NUC를 Tailscale에 다시 등록하면 키 만료가 기본값(켜짐)으로 돌아오고 Tailscale IP가 바뀔 수 있다. 키 만료를 해제한 뒤 apply하면 data source가 새 IP를 쓴다. 만료가 켜진 채면 precondition이 apply를 멈춘다.
  - NUC를 `tag:nuc`로 태그하기로 하면(D-11, 미정) `tag:nuc:53` ACL 규칙이 필요하다.
- AdGuard. 같은 LAN IP `192.168.117.15`의 `:53`으로 서빙해 공유기 설정을 그대로 쓴다. 노드 자신의 DNS에는 함정이 두 개 있다.
  - Tailscale 쪽: k3s 노드 자신은 tailnet 전역 nameserver를 받지 않게 한다.
  - LAN 쪽: 공유기의 주 DNS가 노드 위 AdGuard라서, 노드가 DHCP DNS를 쓰면 "노드 → 공유기 → 노드 위 AdGuard" 순환이 생긴다. 콜드스타트 때 AdGuard가 아직 없으면 이름 해석이 막히고 이미지 pull까지 막힌다.
  - 막는 법: 노드는 공용 DNS를 직접 쓴다. 옛 host-config의 resolved drop-in과 `tailscale set --accept-dns=false`가 하던 일이다. 새 구성에서 이 설정이 있는지 확인한다(명세 §4.5, D-12).
  - 노출은 servicelb다. svclb 출처 MASQUERADE 때문에 클라이언트들이 ratelimit 버킷 하나를 함께 쓰는지 확인한다. 함께 쓰면 `ratelimit_whitelist`나 hostNetwork로 바꾼다. hostNetwork는 노드 네임스페이스 공격면을 늘린다.
  - AdGuard Home이 tailnet에서 조용히 빠져도 공용 서버가 답해 증상이 없다. 관측 스택에 "tailnet 출처 질의가 1시간 0건이면 경보"를 둔다. 이 경보가 이탈을 잡는 유일한 장치라 실제 발화 시험을 완료 조건에 둔다.
- 관측 스택 (D-09). Alertmanager 외부 수신자 연결과 읽기 전용 조회 계정을 포함한다. 읽기 전용 계정은 관측용과 Kubernetes용 둘이다 (AC-P12, 자리 배정은 명세 §4.4).
- 봇과 독립된 비AI 알림 (D-10, AC-P11). 옛 Telegram 봇을 재사용 후보로 둔다.
- 백업용 R2 버킷 (새 이름, 보존 기간).
- 외부 생존 감시 (D-10, AC-P11). 옛 healthchecks.io 데드맨 스위치(Alertmanager Watchdog → relay → ping)를 재사용 후보로 둔다. 체크는 T06에서 일시 정지돼 있다. 재사용하면 새 ping 경로를 연결한 뒤 다시 켠다. 체크의 유지·삭제는 D-11이다. 새 감시가 정상인 것을 확인한 뒤 T06 자격 폐기 표의 `보류(D-10, T08)` 줄(옛 ping URL)을 닫고 [approvals.md](../approvals.md)에 남긴다.
- (잠정, T05에서 확정) 격리 작업 실행 공간 (AC-P12, 명세 §4.2). 운영·게시 자격(kubeconfig, GitHub 쓰기 키, Discord 토큰, SSH, 호스트 소켓)과 운영 네트워크(LAN, 클러스터 내부, Kubernetes API, tailnet, Infisical)에 닿지 못한다. 모델 자격만 별도 시크릿 범위로 받는다. egress는 허용 목록(모델 API, 코드 저장소 읽기, 패키지 레지스트리)으로 제한한다. 봇이 이 공간을 쓰는 세부 방식은 D-15(T15)다.
- Terraform state 잠금 (D-28). 첫 Terraform root를 apply하는 이 티켓에서 R2 `use_lockfile` 동시 실행 시험을 한 번 한다. U02는 R2 PutObject의 If-None-Match 원자성과 S3 backend lockfile 구현으로 문서·소스상 확인됐고 이 시험만 남았다. T10의 `infra/github` 첫 apply는 이 시험 뒤에 한다(설계 E.0).

## 제약

- 외부 변경(터널, DNS, 버킷, Tailscale 설정, 감시·알림 계정)은 사람 승인 뒤에 하고 [../approvals.md](../approvals.md)에 기록한다 (AC-X2).
- Tailscale 전역 DNS의 임시 Cloudflare 항목(C-05)은 D-08대로 지우고 AdGuard 공용 DNS 2개를 넣는다. 바꾸기 전에 콘솔 값을 옮겨 새 state에 import한 Terraform plan이 무변경인지 확인한다.
- 옛 `infra/tailscale` root는 apply도 destroy도 하지 않는다 (명세 §10의 12).

## 완료 조건

- 시나리오 14(DNS), 16(비AI 경보), 17(외부 감시)을 통과한다.
- 시나리오 14에 D-08 추가 확인 둘이 들어간다: 셀룰러 Tailscale 기기 확인(AdGuard 정지 중 광고 도메인 차단, 일반 도메인 정상), 사용자 규칙 적용률 측정(AdGuard Home 전용 시험 차단 규칙을 집 Wi-Fi·셀룰러에서 20회씩, 결과 기록. 시험 이름은 공용 DNS에서 정상 주소가 나오는 `adg-<날짜>-<회차>.ukyi.app`이고 `0.0.0.0` 응답만 차단으로 센다, 설계 G 시나리오 14).
- "tailnet 출처 질의 1시간 0건" 경보의 실제 발화 시험을 통과했다(아래 검증).

## 검증

- AdGuard를 멈추고 LAN 기기, Tailscale 기기(집 Wi-Fi와 셀룰러), 노드 자신의 이름 해석을 각각 확인한다. Tailscale 기기에서는 광고 도메인이 차단되고 일반 도메인이 풀리는지 본다.
- 규칙을 넣기 전에 시험 이름(`adg-<날짜>-<회차>.ukyi.app`)이 두 경로 모두 정상 주소로 풀리는지 본다. 그다음 AdGuard Home에만 있는 시험 차단 규칙으로 집 Wi-Fi와 셀룰러의 Tailscale 기기에서 20회씩 조회해 `0.0.0.0` 응답 수를 기록하고 AdGuard Home 질의 로그와 대조한다. 없는 이름은 공용 서버도 NXDOMAIN이라 차단으로 잘못 세므로 쓰지 않는다.
- AdGuard Home이 tailnet 질의를 받지 못하는 상태를 만든다(NUC를 `tag:nuc`로 태그했으면 정책 사본을 남기고 `tag:nuc:53` 규칙을 뺀 정책 apply, 승인 기록. 태그하지 않아 `autogroup:self:*`가 모든 포트를 열면 사람이 sudo로 `tailscale0`의 53번을 raw PREROUTING에서 임시 차단하고 시험 뒤 지운다, 설계 E4b). 1시간 무질의 뒤 다음 평가 주기 안에 Telegram 경보가 오는지 확인하고, 정책을 되돌린 뒤 resolved를 확인한다. 그 동안 Tailscale 기기는 공용 서버로 해석한다.
- Tailscale DNS root에 콘솔 값을 옮겨 import한 뒤 첫 plan이 무변경인지 확인한다.
- svclb를 거친 질의의 출처 주소와 ratelimit 버킷 공유 여부를 확인한다.
- 같은 state로 Terraform을 동시에 두 번 실행해 하나가 잠금으로 멈추는지 확인한다(U02).
- 테스트 경보를 보내 봇 없이 도착하는지 확인한다.
- NUC 네트워크를 끊고 외부 감시 알림이 오는지 확인한다.
- 새 ACL을 적용한 뒤 원격에서 NUC로 Tailscale SSH 접속이 되는지 확인한다.
