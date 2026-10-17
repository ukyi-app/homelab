# T08 기반 플랫폼

- 단계: P2 플랫폼 구축 (잠정)
- 상태: 대기
- 명세: [../spec.md](../spec.md) §4.2
- Blocked by: T07, T09
- 선행 결정: D-08, D-09, D-10, D-11 (Tailscale ACL·DNS 덮어쓰기, zone 설정, healthchecks.io 체크)
- 연결 AC: AC-P6, AC-P11, AC-P12
- 수행: 에이전트 + 사람 (Cloudflare·Tailscale 콘솔, 토큰, 외부 감시·비AI 알림 채널 계정·토큰. 명세 §11)

## 목표

CI/CD와 앱이 올라갈 네트워크·DNS·관측·알림·백업을 세운다.

## 입력

- T06이 내보낸 옛 AdGuard 라이브 설정 (비밀값 제외).

## 범위

- Cloudflare 터널과 인그레스. 공개 webhook 수신 경로를 포함한다. `ukyi.app` zone에 HSTS(includeSubDomains, 180일)가 걸려 있어서, `*.home.ukyi.app` 내부 UI도 처음부터 유효한 인증서의 HTTPS로 띄운다. 평문 HTTP나 자체 서명 인증서는 브라우저가 열어 주지 않는다.
- Tailscale operator와 DNS 설정 (D-08). 새 ACL은 `autogroup:self` 허용과 ssh 규칙을 유지한다. 빠지면 운영자의 NUC 원격 접속이 끊긴다. NUC를 Tailscale에 다시 등록하면 키 만료가 기본값(켜짐)으로 돌아온다. 키 만료를 해제하고, 전역 nameserver에 든 NUC Tailscale IP를 새 값으로 갱신한다.
- AdGuard. 같은 LAN IP `192.168.117.15`의 `:53`으로 서빙해 공유기 설정을 그대로 쓴다. 노드 자신의 DNS에는 함정이 두 개 있다.
  - Tailscale 쪽: k3s 노드 자신은 tailnet 전역 nameserver를 받지 않게 한다.
  - LAN 쪽: 공유기의 주 DNS가 노드 위 AdGuard라서, 노드가 DHCP DNS를 쓰면 "노드 → 공유기 → 노드 위 AdGuard" 순환이 생긴다. 콜드스타트 때 AdGuard가 아직 없으면 이름 해석이 막히고 이미지 pull까지 막힌다.
  - 막는 법: 노드는 공용 DNS를 직접 쓴다. 옛 host-config의 resolved drop-in과 `tailscale set --accept-dns=false`가 하던 일이다. 새 구성에서 이 설정이 있는지 확인한다(명세 §4.5, D-12).
- 관측 스택 (D-09). Alertmanager 외부 수신자 연결과 읽기 전용 조회 계정을 포함한다. 읽기 전용 계정은 관측용과 Kubernetes용 둘이다 (AC-P12, 자리 배정은 명세 §4.4).
- 봇과 독립된 비AI 알림 (D-10, AC-P11). 옛 Telegram 봇을 재사용 후보로 둔다.
- 백업용 R2 버킷 (새 이름, 보존 기간).
- 외부 생존 감시 (D-10, AC-P11). 옛 healthchecks.io 데드맨 스위치(Alertmanager Watchdog → relay → ping)를 재사용 후보로 둔다. 체크는 T06에서 일시 정지돼 있다. 재사용하면 새 ping 경로를 연결한 뒤 다시 켠다. 체크의 유지·삭제는 D-11이다.
- (잠정, T05에서 확정) 격리 작업 실행 공간 (AC-P12, 명세 §4.2). 운영·게시 자격(kubeconfig, GitHub 쓰기 키, Discord 토큰, SSH, 호스트 소켓)과 운영 네트워크(LAN, 클러스터 내부, Kubernetes API, tailnet, Infisical)에 닿지 못한다. 모델 자격만 별도 시크릿 범위로 받는다. egress는 허용 목록(모델 API, 코드 저장소 읽기, 패키지 레지스트리)으로 제한한다. 봇이 이 공간을 쓰는 세부 방식은 D-15(T15)다.

## 제약

- 외부 변경(터널, DNS, 버킷, Tailscale 설정, 감시·알림 계정)은 사람 승인 뒤에 하고 [../approvals.md](../approvals.md)에 기록한다 (AC-X2).
- Tailscale 전역 DNS의 임시 Cloudflare 항목(C-05)은 D-08 결정대로 정리한다.
- 옛 `infra/tailscale` root는 apply도 destroy도 하지 않는다 (명세 §10의 12).

## 완료 조건

시나리오 14(DNS), 16(비AI 경보), 17(외부 감시)을 통과한다.

## 검증

- AdGuard를 멈추고 LAN 기기, Tailscale 기기, 노드 자신의 이름 해석을 각각 확인한다.
- 테스트 경보를 보내 봇 없이 도착하는지 확인한다.
- NUC 네트워크를 끊고 외부 감시 알림이 오는지 확인한다.
- 새 ACL을 적용한 뒤 원격에서 NUC로 Tailscale SSH 접속이 되는지 확인한다.
