# T13 테스트 앱 통합 검증

- 단계: P2 플랫폼 구축 (플랫폼 통합 검증 담당, 재분해 T05 2026-10-18)
- 상태: 완료(2026-10-29. 2026-10-26 착수. 시나리오 1~17 실행, 모든 줄이 실제 검증 완료 또는 사용자가 승인한 한계·편차·갈음. 결과표 `platform/verification.md`. U40 2회차는 T23. 시험 앱 정리는 되돌리는 방법대로 따로)
- 명세: [../spec.md](../spec.md) §9
- Blocked by: T08a, T08b, T08c, T10, T11, T12
- 선행 결정: D-12 (확정(사용자 2026-10-18, T05): 빈 NUC 검증은 VM, 설계 E8 VM 격리 조건 여섯, VM 호스트는 tailnet 밖), D-08 (확정(사용자 2026-10-18): 시나리오 14 추가 확인), D-29 (확정(사용자 2026-10-18): 시험 앱 저장소도 public), D-30 (확정(사용자 2026-10-20): 내부 UI 짧은 주소 리다이렉터 `go`, VM은 `vm-go`)
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
   - (2) Infisical: VM의 ESO는 프로젝트 `homelab-dev`(환경 `dev`)를 VM 전용 identity `eso-homelab-dev`으로만 읽는다. 운영 ExternalSecret 키 목록을 운영 클러스터에서 뽑아 `homelab-dev`의 같은 경로에 시험 값을 채우고, 키 이름만 `comm -23`으로 대조해 빠진 키 0을 확인한다. 운영 값을 복사하지 않는다.
   - (3) 백업 버킷과 serverName: VM 전용 R2 버킷(예: `homelab-backups-vm`)과 serverName `pg-vm-<YYYYMMDD>`로만 아카이브한다. 운영 아카이브는 복구 원본으로만 쓰고, 그 자격은 복구 자산의 R2 읽기 전용 토큰으로 VM에 손으로 넣는 Secret 하나다(Infisical 밖). 복구 PR을 VM root apply 전에 병합하고, 시험 뒤 정리 PR로 values-vm의 복구 원본을 지운다(설계 C.6.4와 같은 순서).
   - (4) Tailscale 이름: VM operator Ingress와 operator 자신의 기기 이름에 `vm-` 접두를 쓰고, VM operator OAuth client를 따로 발급한다. VM 호스트는 tailnet에 넣지 않는다(`vm.env`의 `TAILNET_JOIN=false`). 접근은 LAN 주소나 콘솔로 한다. C.6.4 복구 순서의 "옛 클러스터 operator·프록시 기기 삭제" 단계는 건너뛰고, 시험 뒤 `vm-*` 기기만 지운다. VM은 운영 Tailscale 기기를 건드리지 않는다.
     - D-30 리다이렉터: 운영자 기기에서 `vm-go/argocd`가 `vm-argocd`의 tailnet 주소로 넘어가는지 본다(T08c는 렌더만 확인했다). VM의 tailnet 도메인 키는 `homelab-dev`에서 온다.
   - (5) 공개 터널·감시·알림: 시험 터널(별도 토큰), 시험 healthchecks 체크, 시험 Telegram 수신자(시험 봇 토큰)를 쓴다. VM은 운영 공개 URL을 쓰지 않는다. 공개 경로는 VM cloudflared `/ready` 200과 `cloudflared_tunnel_ha_connections` 1 이상, Traefik port-forward에 `Host: smoke.ukyi.app` 헤더로 `/healthz` 200과 없는 host 404로 확인한다. 운영 DNS 레코드를 VM용으로 바꾸지 않는다.
   - (6) kubeconfig: context를 `homelab-vm`으로 각인한다.
   - 이 시나리오에서 U27(읽기 전용 토큰으로 plugin 복구)을 보고, U40(클러스터 유실과 Infisical 장애가 겹친 복구)은 VM에서 Infisical 접근을 막고 시나리오 13을 한 번 더 해서 본다(설계 부록 1).
3. 실패와 미실행 항목마다 후속 티켓을 만들거나 한계로 명시한다.
4. 봇을 위한 여지(AC-P12 다섯 자리, 리뷰 전용 App 저장소별 설치 포함)의 경로·계정·설치 가능 여부를 실제로 확인한다. 다섯 자리는 명세 §4.4에 있다. 모든 봇·병합·알림 자리의 최종 확인은 이 티켓이다(설계 E.3). 자리마다 설계 C.8 표의 준비 확인 방법으로 다시 본다. 괄호는 먼저 준비한 티켓이다.
   - AC-P12: 공개 HTTPS webhook 수신 경로(T08a), 읽기 전용 접근 Kubernetes·관측·Argo CD(T08b), 경보 외부 수신자(T08b), 격리 작업 실행 공간(T08b), 리뷰 전용 App 저장소별 설치 구조(T10).
   - AC-P8: 병합 조건 공개(T10), 봇 변경 PR의 자동 병합 차단(T10, 시험 신원. 실제 신원은 T19).
   - AC-P11: 비AI 알림 경로(T08b), 외부 생존 감시(T08b).
5. 배포 갱신 주체가 아닌 신원의 digest PR이 자동 병합되지 않는지 확인한다 (AC-P8). 시험 App(봇 신원 대역)을 새로 만들어 `homelab-smoke`에 설치하고 시나리오 15로 본다. T10의 `ukyi-homelab-bot-standin`은 2026-10-21 시험 뒤 삭제했으므로 새 이름(예: `ukyi-homelab-bot-standin-2`)과 새 키로 만들고, 시험이 끝나면 지운다(권한은 contents·pull requests 쓰기, webhook 없음).
6. 시나리오 14에 D-08 추가 확인을 넣는다: 셀룰러 Tailscale 기기(AdGuard 정지 중 광고 도메인 차단, 일반 도메인 정상), 사용자 규칙 적용률(AdGuard Home 전용 시험 차단 규칙을 집 Wi-Fi·셀룰러에서 20회씩. 공용 DNS에서 정상 주소가 나오는 시험 이름을 쓰고 `0.0.0.0` 응답만 센다, 설계 G 시나리오 14). 측정값을 결과표에 남긴다.
7. 시나리오 7·13 뒤 복구 자산의 운영 ESO client ID·secret으로 Infisical Universal Auth에 로그인해 성공을 확인한다. 토큰은 출력하지 않고 응답 코드만 본다. 시나리오 7의 장애 주입이 운영 client secret을 폐기하지 않았음을 확인하는 것이다(설계 E8).
8. T07에서 넘긴 일(2026-10-19, PR #755 Codex 리뷰): `platform/root/values-vm.yaml`은 키 모양만 있고 값이 비어 있으며 빈 값을 막는 검사가 없다. VM 값을 채울 때 `templates/cluster-check.yaml`에 VM 격리 값(Infisical 프로젝트·환경, CNPG 버킷·serverName, Tailscale 이름 접두)이 비면 렌더가 실패하는 검사를 더한다. 그 전에는 `root-vm.yaml`을 apply하지 않는다(`bootstrap.md` 0절).
9. T10에서 넘긴 일(2026-10-21, 사용자 승인 한계): 새 파드는 시작 직후 약 1초 동안 NetworkPolicy가 붙기 전이라 egress가 모두 열린다(k3s 내장 kube-router netpol의 동기화 지연, approvals 15:48 행, 설계 B.8 E5). 완화 전에 시작 직후 파드가 닿는 범위를 전체로 조사한다(T10은 Argo CD tailnet 443, 공유기 80·443, kube API, 공개 인터넷 `1.1.1.1:80`만 실측했다. 같은 LAN의 다른 호스트·포트, ACL상 다른 허용 대상, 공개 인터넷의 443 밖 포트도 본다). 공개 인터넷의 443 밖 egress는 아래 nftables 규칙이 막지 않으므로, 막을 방법(예: 파드 대역의 공개 대역 forward를 443만 허용)을 정하거나 남는 한계로 사용자 승인을 받는다. 그다음 노드 nftables에서 파드 대역(`10.42.0.0/16`)이 tailnet(`100.64.0.0/10`)과 LAN 사설 대역으로 나가는 forward를 정책과 상관없이 막는 규칙을 `host/`에 넣고(그 길이 필요한 파드가 있는지 먼저 조사), 시작 즉시 연결하는 시험 파드로 재시험한다. 사용자 결정 1안(2026-10-26)대로 넣었다(#919, 커널 판정 보강 #926). 2026-10-26 운영에 적용한 뒤 시작 즉시 연결하는 시험 파드가 15/15 통과했다. 남는 한계는 런북 `bootstrap.md` 1.1이다.

## 필요한 자격

설계 E8 선행 조건의 사람 작업이다. VM 쪽 값은 운영과 같은 키 이름으로 `homelab-dev`/`dev`에 두고 운영 값을 복사하지 않는다.

- `eso-homelab-dev`의 Universal Auth client secret: identity는 T09가 만들었다. client secret은 이 티켓에서 VM을 준비할 때 발급해 저장소 밖 VM 준비 자산(복구 자산과 따로 표시한 항목)에 두고, VM 폐기 때 폐기한다.
- VM 전용 R2 버킷과 그 버킷 전용 Object Read & Write 토큰: 이 티켓에서 사람이 만든다. 토큰은 `homelab-dev`에 둔다.
- VM operator OAuth client, 시험 터널 토큰, 시험 healthchecks 체크 ping URL, 시험 Telegram 봇 토큰: 이 티켓에서 사람이 발급해 `homelab-dev`에 둔다.
- 그 밖의 `homelab-dev` 시험 값(Grafana·AdGuard·Argo CD 관리자 자격, `homelab-smoke`의 앱 키·DB·Valkey 비밀번호 등): 이 티켓에서 새 시험 값으로 채운다.
- 복구 자산의 R2 읽기 전용 토큰(운영 백업 버킷만): 시나리오 13 동안만 VM에 손으로 넣는다. 복구 자산 목록은 T09가 만든다. 이 토큰을 발급하는 티켓은 설계에 정해져 있지 않다 [미검증].
- 복구 자산의 운영 ESO client ID·secret: 준비 T09. 할 일 7의 로그인 확인에 쓴다.
- 시험 App(봇 신원 대역): T10의 `ukyi-homelab-bot-standin`은 삭제했다(2026-10-21). 이 티켓에서 새 이름(예: `ukyi-homelab-bot-standin-2`)으로 만들어 `homelab-smoke`에 설치하고, 새 키는 시험 직전에 받아 끝나면 App째 지운다(마지막 키는 따로 지울 수 없다).
- CLI가 쓰는 사람의 `gh` 로그인, `infisical login`, kubeconfig(운영 context와 `homelab-vm`).
- NUC 재부팅·네트워크 차단 시험(시나리오 12·17)은 사람 승인 뒤에 한다. 시나리오 17의 물리 차단(전원 또는 네트워크)은 여기서 처음 한다. T08b는 파드에서 healthchecks ping 주소로 가는 443만 막아 대신했다(사용자 결정 2026-10-23).

## 완료 조건

- 시나리오 1~17이 모두 `실제 검증 완료`이거나, 사용자가 승인한 한계로 기록돼 있다.
- 할 일 4의 AC-P12 다섯 자리와 AC-P11·AC-P8 자리를 확인했다.
- 필수 시나리오에 실패나 미실행이 남아 있으면 T13은 완료가 아니다. 수정 티켓을 만들고, 수정 뒤 해당 시나리오를 다시 실행한다. T16b·T22는 T13이 완료돼야 시작한다. T16a(봇 로컬·mock)는 T13을 기다리지 않는다.

## 검증

설계 G절 전체를 실행한다. 결과표의 각 줄에 실행 명령, 시각, 증거 위치가 있다. 결과표는 설계 문서 G절 옆(`platform/verification.md`)에 두고 PR로 main에 병합한다(명세 AC-X1). 공개되면 안 되는 증거는 저장소 밖에 두고 위치만 적는다.

- 확인한 항목(2026-10-27~29 최종 결과, 기록은 `approvals.md`의 같은 날 행. 결과표 [../platform/verification.md](../platform/verification.md), 명령 출력 원문은 저장소 밖):
  - 할 일 1(시나리오 1~17): 1~17과 15의 15-1~15-13을 모두 실행했다. 1과 14는 `승인된 한계`(1: tailnet 확인 대상 대체·egress 규칙의 남는 한계, 14: LAN AC-P6), 13은 `실제 검증 완료(편차 승인)`, 그 밖에 실행한 시나리오는 `실제 검증 완료`다(2의 retry 수렴은 T11 증거로, 6의 Telegram 수신은 전송 지표로 갈음, 사용자 결정 2026-10-28). 12는 재부팅 지시부터 전부 정상까지 5분 24초, 14의 LAN은 AdGuard 정지 동안 30/30 실패(AC-P6 한계 승인 2026-10-20)다. 17은 2026-10-29 전원 차단(`rtcwake` 정상 종료·RTC 기상)으로 실행해 down 알림 07:09·up 알림 07:15를 받았다(수신 시각으로 갈음, 사용자 결정 2026-10-29). 15-13은 이 결과 PR에서 봤다. <!-- TODO lead: 15-13 결과 --> `homelab-smoke`는 `homelab app new homelab-smoke --apply`(목록 PR #923)로 만들었고, 두 번째 시험 DB는 `homelab-smoke2`(손 PR #939)다. CLI 시나리오와 공개 URL(`https://smoke.ukyi.app/healthz` 200)을 모두 실행했다.
  - 할 일 2(시나리오 13, VM): VM 격리 조건 여섯을 모두 확인했다. U27(읽기 전용 토큰으로 plugin 복구) 통과, U26 Argo CD 경로 통과. U40 2회차는 하지 않았다(사용자 결정 2026-10-27, 한계·후속). 실행 중 문서에 없는 단계가 하나 있었다(운영 NUC inotify 한도 128 소진, #960 실행 중 병합·적용과 libvirtd 재시작). 운영 NUC 위에 VM을 띄운 시험 환경이 원인이고 지금은 vm.md 1.1 사전 확인이 먼저 막아, 사용자가 편차로 승인했고 재실행하지 않는다(2026-10-28).
  - 할 일 3(실패·미실행): 결과표 "한계와 후속"에 시나리오별로 적었다. 준비 PR은 #915~#921과 앱 템플릿 PR #44, 실행 중 고친 PR은 #924·#926·#935·#950·#957·#958·#960·#968·#969·#971이다. 시나리오 9에서 본 재등록의 `values.yaml` 동작은 이 결과 PR에서 `cli/README.md`와 설계 C.7에 경고로 적었다. 시나리오 6에서 본 Argo CD 재시도 함정의 작업 끝내기 절차(#957, 런북 `apps.md` 1.3 4단계)는 #972·#973으로 운영 실측했다(되돌림 병합부터 복구까지 36초, 사용자 승인 2026-10-28).
  - 할 일 4·5(봇·병합·알림 자리): 결과표 "봇 자리 확인"(2026-10-27 17:47~17:50, 읽기만). 아홉 자리 중 여덟이 실제 검증 완료다. 리뷰 전용 App 저장소별 설치 구조는 T10 증거로 갈음했다(사용자 결정 2026-10-27, 승인된 한계). 외부 생존 감시의 NUC 전체 중단은 시나리오 17(2026-10-29)에서 확인했다. 할 일 5는 새 대역 App `ukyi-homelab-bot-standin-2`(ID 5491621)로 시나리오 15-7에서 봤고, App과 키는 시험 뒤 지웠다.
  - 할 일 6(D-08 추가 확인): 시나리오 14(2026-10-28)에서 셀룰러 Tailscale 기기는 AdGuard 정지 중 `doubleclick.net` → `0.0.0.0`, `example.com` 정상(U33 통과). 사용자 규칙 적용률은 집 Wi-Fi 0/20, 셀룰러 1/20으로 2026-10-21(20/20, 19/20)보다 크게 낮다. 원인은 운영자 맥의 AdGuard for Mac DNS 보호(제공자 AdGuard DNS DoH)가 시스템 DNS 질의를 가로챈 것이었다. 2026-10-29 제공자를 "시스템 기본 설정"으로 바꾼 뒤 질의가 NUC에 도착했다(플랫폼 결함 아님, 결과표 "한계와 후속" 14).
  - 할 일 7: 시나리오 13 정리 뒤(2026-10-28) 복구 자산의 운영 ESO client ID·secret으로 Universal Auth 로그인 HTTP 200(토큰은 버림). 시나리오 7 직후에는 따로 로그인하지 않고 원복 뒤 ClusterSecretStore Ready=True와 원본 해시 일치를 봤다.
  - 할 일 8: VM 격리 값 검사는 #916(values-vm VM 프로필 단언)으로 넣었고, `root-vm` apply는 그 뒤(2026-10-28 02:31Z)다.
  - 할 일 9: 사용자 결정 1안(2026-10-26)대로 노드 nftables로 파드 대역의 LAN·tailnet·공개 비443 출발을 막았다(#919, 커널 판정 보강 #926). 2026-10-26 운영 적용 뒤 시작 즉시 연결하는 시험 파드가 15/15 통과했다. 남는 한계는 런북 `bootstrap.md` 1.1이다. 그중 부팅 fail-open(한계 5)은 사용자가 한계로 승인했고(2026-10-28), 시나리오 12 뒤 1.1의 시험 파드 블록이 통과했다(2026-10-28, 15/15). 1안이 요구한 운영자 기기의 tailnet UI(DERP) 실측은 시나리오 14 중 운영자 맥(셀룰러)의 브라우저로 Grafana·Argo CD가 열린 것으로 확인했다.
  - 정리: VM·VM 버킷·`vm-*` 기기·`eso-homelab-dev` client secret·시험 터널·체크·Telegram 봇과 `homelab-dev` 외부 자격 키는 지웠다(2026-10-28). 대역 App·GHCR 시험 버전(2026-10-27), values-vm 복구 원본(#964)도 지웠다. 남은 것: `homelab-smoke`·`homelab-smoke2` 정리(`app remove` → `data purge`, Infisical 시험 키 포함), R2 되돌림 사본(사람 작업), `homelab-smoke` main의 `src/slow.test.ts`. libvirt iptables 체인은 시나리오 12 뒤 vm.md 6.3 "남은 것 0"으로 확인했다(2026-10-28 23:59).
- 후속(이 티켓 밖으로 넘김):
  - T16b: 시험 수신기 `edge-probe`를 봇으로 바꾸고 지운다(`platform/edge-probe` 주석). 봇 경보 route, Grafana·Argo CD `bot-reader` 토큰, `auth.json` 시드는 이미 T16b 할 일이다.
  - T17: 실제 리뷰 App 권한에 `issues read`(설계 C.8에 있음, T10 시험 App에는 빠져 있었다).
  - U40 2회차: 사용자 결정(2026-10-27)으로 한계·후속이다. 후속 티켓은 [T23](T23-platform-followups.md)이다(사용자 결정 2026-10-29).
  - 시나리오 17의 부팅 오경보(`AdGuardTailnetQueriesMissing`, svclb 새 IP): [T23](T23-platform-followups.md) 할 일 4.

## 되돌리는 방법

설계 E8 "되돌리는 방법"을 따른다.

- 시험 앱은 `homelab app remove` 뒤 `homelab data purge`로 지운다.
- VM은 폐기한다. VM 전용 R2 버킷과 tailnet의 `vm-*` 기기(VM operator·프록시)를 지운다.
- `eso-homelab-dev` client secret을 폐기한다.
- values-vm의 복구 원본은 정리 PR로 지운다.
