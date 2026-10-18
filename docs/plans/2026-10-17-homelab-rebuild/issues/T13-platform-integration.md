# T13 테스트 앱 통합 검증

- 단계: P2 플랫폼 구축 (플랫폼 통합 검증 담당, 재분해 T05 2026-10-18)
- 상태: 대기
- 명세: [../spec.md](../spec.md) §9
- Blocked by: T08a, T08b, T10, T11, T12
- 선행 결정: D-12 (확정(사용자 2026-10-18, T05): 빈 NUC 검증은 VM, 설계 E8 VM 격리 조건 여섯, VM 호스트는 tailnet 밖), D-08 (확정(사용자 2026-10-18): 시나리오 14 추가 확인), D-29 (확정(사용자 2026-10-18): 시험 앱 저장소도 public)
- 연결 AC: AC-P5~AC-P13
- 수행: 에이전트 + 사람

## 목표

테스트 앱 하나로 플랫폼 프롬프트 §9 시나리오 전체(1~17)를 실행해 플랫폼을 판정한다. 시험 앱은 T12의 CLI로 새로 만드는 `homelab-smoke`다(설계 E8).

## 할 일

1. 시나리오 1~17을 실행하고 각각 `실제 검증 완료 / 설계상 기대 / 실패`로 기록한다.
   - `homelab-smoke`는 `homelab app new homelab-smoke --apply`로 만든다(시나리오 1, 열린 `app-repos.json` PR 병합 뒤 한 번 더). 두 번째 시험 DB는 `homelab-smoke2`다.
   - CLI를 쓰는 시나리오와 공개 URL 확인(시나리오 1의 `curl -sf https://smoke.ukyi.app/healthz` 포함)을 모두 실행한다. T10·T11은 CLI와 공개 URL 없이 먼저 통과시켰다.
   - 결과표는 `platform/verification.md`(설계 문서 옆)다.
2. 시나리오 13(빈 환경 재구축)은 D-12 방식(확정: VM)으로 실행한다. VM은 설계 E8 "VM 격리"의 조건 여섯을 지킨다.
   - (1) 클러스터 값 주입: `platform/root/values-vm.yaml`, root `root-vm.yaml`(T07이 만들어 둠), 호스트 값 파일 `host/clusters/vm.env`(노드 이름 `vm-` 접두, 운영자 기기가 LAN으로 닿는 노드 IP). VM 값 파일 둘은 VM 시험 전에 PR로 채운다. 시크릿의 키 이름은 클러스터 값으로 바꾸지 않고 운영과 같다.
   - (2) Infisical: VM의 ESO는 프로젝트 `homelab-dev`(환경 `dev`)를 VM 전용 identity `eso-homelab-vm`으로만 읽는다. 운영 ExternalSecret 키 목록을 운영 클러스터에서 뽑아 `homelab-dev`의 같은 경로에 시험 값을 채우고, 키 이름만 `comm -23`으로 대조해 빠진 키 0을 확인한다. 운영 값을 복사하지 않는다.
   - (3) 백업 버킷과 serverName: VM 전용 R2 버킷(예: `homelab-backups-vm`)과 serverName `pg-vm-<YYYYMMDD>`로만 아카이브한다. 운영 아카이브는 복구 원본으로만 쓰고, 그 자격은 복구 자산의 R2 읽기 전용 토큰으로 VM에 손으로 넣는 Secret 하나다(Infisical 밖). 복구 PR을 VM root apply 전에 병합하고, 시험 뒤 정리 PR로 values-vm의 복구 원본을 지운다(설계 C.6.4와 같은 순서).
   - (4) Tailscale 이름: VM operator Ingress와 operator 자신의 기기 이름에 `vm-` 접두를 쓰고, VM operator OAuth client를 따로 발급한다. VM 호스트는 tailnet에 넣지 않는다(`vm.env`의 `TAILNET_JOIN=false`). 접근은 LAN 주소나 콘솔로 한다. C.6.4 복구 순서의 "옛 클러스터 operator·프록시 기기 삭제" 단계는 건너뛰고, 시험 뒤 `vm-*` 기기만 지운다. VM은 운영 Tailscale 기기를 건드리지 않는다.
   - (5) 공개 터널·감시·알림: 시험 터널(별도 토큰), 시험 healthchecks 체크, 시험 Telegram 수신자(시험 봇 토큰)를 쓴다. VM은 운영 공개 URL을 쓰지 않는다. 공개 경로는 VM cloudflared `/ready` 200과 `cloudflared_tunnel_ha_connections` 1 이상, Traefik port-forward에 `Host: smoke.ukyi.app` 헤더로 `/healthz` 200과 없는 host 404로 확인한다. 운영 DNS 레코드를 VM용으로 바꾸지 않는다.
   - (6) kubeconfig: context를 `homelab-vm`으로 각인한다.
   - 이 시나리오에서 U27(읽기 전용 토큰으로 plugin 복구)을 보고, U40(클러스터 유실과 Infisical 장애가 겹친 복구)은 VM에서 Infisical 접근을 막고 시나리오 13을 한 번 더 해서 본다(설계 부록 1).
3. 실패와 미실행 항목마다 후속 티켓을 만들거나 한계로 명시한다.
4. 봇을 위한 여지(AC-P12 다섯 자리, 리뷰 전용 App 저장소별 설치 포함)의 경로·계정·설치 가능 여부를 실제로 확인한다. 다섯 자리는 명세 §4.4에 있다. 모든 봇·병합·알림 자리의 최종 확인은 이 티켓이다(설계 E.3). 자리마다 설계 C.8 표의 준비 확인 방법으로 다시 본다. 괄호는 먼저 준비한 티켓이다.
   - AC-P12: 공개 HTTPS webhook 수신 경로(T08a), 읽기 전용 접근 Kubernetes·관측·Argo CD(T08b), 경보 외부 수신자(T08b), 격리 작업 실행 공간(T08b), 리뷰 전용 App 저장소별 설치 구조(T10).
   - AC-P8: 병합 조건 공개(T10), 봇 변경 PR의 자동 병합 차단(T10, 시험 신원. 실제 신원은 T19).
   - AC-P11: 비AI 알림 경로(T08b), 외부 생존 감시(T08b).
5. 배포 갱신 주체가 아닌 신원의 digest PR이 자동 병합되지 않는지 확인한다 (AC-P8). T10의 시험 App을 `homelab-smoke`에도 설치해 시나리오 15로 본다.
6. 시나리오 14에 D-08 추가 확인을 넣는다: 셀룰러 Tailscale 기기(AdGuard 정지 중 광고 도메인 차단, 일반 도메인 정상), 사용자 규칙 적용률(AdGuard Home 전용 시험 차단 규칙을 집 Wi-Fi·셀룰러에서 20회씩. 공용 DNS에서 정상 주소가 나오는 시험 이름을 쓰고 `0.0.0.0` 응답만 센다, 설계 G 시나리오 14). 측정값을 결과표에 남긴다.
7. 시나리오 7·13 뒤 복구 자산의 운영 ESO client ID·secret으로 Infisical Universal Auth에 로그인해 성공을 확인한다. 토큰은 출력하지 않고 응답 코드만 본다. 시나리오 7의 장애 주입이 운영 client secret을 폐기하지 않았음을 확인하는 것이다(설계 E8).

## 필요한 자격

설계 E8 선행 조건의 사람 작업이다. VM 쪽 값은 운영과 같은 키 이름으로 `homelab-dev`/`dev`에 두고 운영 값을 복사하지 않는다.

- `eso-homelab-vm`의 Universal Auth client secret: identity는 T09가 만들었다. client secret은 이 티켓에서 VM을 준비할 때 발급해 저장소 밖 VM 준비 자산(복구 자산과 따로 표시한 항목)에 두고, VM 폐기 때 폐기한다.
- VM 전용 R2 버킷과 그 버킷 전용 Object Read & Write 토큰: 이 티켓에서 사람이 만든다. 토큰은 `homelab-dev`에 둔다.
- VM operator OAuth client, 시험 터널 토큰, 시험 healthchecks 체크 ping URL, 시험 Telegram 봇 토큰: 이 티켓에서 사람이 발급해 `homelab-dev`에 둔다.
- 그 밖의 `homelab-dev` 시험 값(Grafana·AdGuard·Argo CD 관리자 자격, `homelab-smoke`의 앱 키·DB·Valkey 비밀번호 등): 이 티켓에서 새 시험 값으로 채운다.
- 복구 자산의 R2 읽기 전용 토큰(운영 백업 버킷만): 시나리오 13 동안만 VM에 손으로 넣는다. 복구 자산 목록은 T09가 만든다. 이 토큰을 발급하는 티켓은 설계에 정해져 있지 않다 [미검증].
- 복구 자산의 운영 ESO client ID·secret: 준비 T09. 할 일 7의 로그인 확인에 쓴다.
- T10이 만든 시험 App: `homelab-smoke`에도 설치한다(시나리오 15).
- CLI가 쓰는 사람의 `gh` 로그인, `infisical login`, kubeconfig(운영 context와 `homelab-vm`).
- NUC 재부팅·네트워크 차단 시험(시나리오 12·17)은 사람 승인 뒤에 한다.

## 완료 조건

- 시나리오 1~17이 모두 `실제 검증 완료`이거나, 사용자가 승인한 한계로 기록돼 있다.
- 할 일 4의 AC-P12 다섯 자리와 AC-P11·AC-P8 자리를 확인했다.
- 필수 시나리오에 실패나 미실행이 남아 있으면 T13은 완료가 아니다. 수정 티켓을 만들고, 수정 뒤 해당 시나리오를 다시 실행한다. T16·T22는 T13이 완료돼야 시작한다.

## 검증

설계 G절 전체를 실행한다. 결과표의 각 줄에 실행 명령, 시각, 증거 위치가 있다. 결과표는 설계 문서 G절 옆(`platform/verification.md`)에 두고 PR로 main에 병합한다(명세 AC-X1). 공개되면 안 되는 증거는 저장소 밖에 두고 위치만 적는다.

## 되돌리는 방법

설계 E8 "되돌리는 방법"을 따른다.

- 시험 앱은 `homelab app remove` 뒤 `homelab data purge`로 지운다.
- VM은 폐기한다. VM 전용 R2 버킷과 tailnet의 `vm-*` 기기(VM operator·프록시)를 지운다.
- `eso-homelab-vm` client secret을 폐기한다.
- values-vm의 복구 원본은 정리 PR로 지운다.
