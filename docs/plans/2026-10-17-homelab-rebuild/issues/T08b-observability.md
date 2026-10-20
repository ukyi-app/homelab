# T08b 관측·알림·봇 자리

- 단계: P2 플랫폼 구축 (재분해 T05 2026-10-18)
- 상태: 대기
- 명세: [../spec.md](../spec.md) §4.2, §4.4
- 설계: [../platform/design.md](../platform/design.md) E.1 E4b, E.3, C.3.7, C.8
- Blocked by: T08a, T09
- 선행 결정: D-08 (확정(사용자 2026-10-18): Tailscale DNS (b′). 그래서 tailnet 출처 질의 1시간 0건 경보를 둔다), D-09 (확정(사용자 2026-10-18, T05): 옛 계열 최소 구성), D-10 (확정(사용자 2026-10-18, T05): homelab 알림용 Telegram 새 봇 + healthchecks.io 계정 재사용·새 체크), D-11 (확정(사용자 2026-10-18, T05): Tailscale ACL (a), 옛 healthchecks 체크는 새 체크가 초록이 된 뒤 삭제), D-20 (확정(사용자 2026-10-18, T05): 모든 값 새로 발급, 옛 healthchecks ping URL은 `보류(D-10, T08b)`), 격리 작업 공간 기본 방식 (확정(사용자 2026-10-18, T05): 설계 C.8 기본값), D-14 (확정(사용자 2026-10-18, T15): 봇 전용 ChatGPT 구독 계정 + 작업자 전용 CODEX_HOME. 이 티켓에 주는 것은 인증 갱신본을 되쓰는 작업자 전용 영속 쓰기 공간(`CODEX_HOME`용 PVC 하나, 설계 C.8 변경)과 작업 직렬 1개다), D-15 (확정(사용자 2026-10-18, T15): 작업자는 `sandbox` ns 상주 파드 하나(동시성 1), 앱·작업자 포트 8080, 경보 수신 포트 8081, 라벨 `homelab-bot`(봇 값은 T16b가 `target`에 넣는다). 작업자 코드 읽기는 `codeload.github.com`만이고 egress에서 `github.com`·`api.github.com`·`gist.github.com`을 뺀다. 파드 방화벽(U13)이 안 되면 호스트 전용 UID + nft)
- 연결 AC: AC-P6, AC-P10, AC-P11, AC-P12
- 수행: 에이전트 + 사람 (healthchecks.io 새 체크와 옛 체크 삭제, 새 Telegram 봇의 수신 chat 확인, 시험 경보·장애 주입 승인, 이탈 시험의 sudo 임시 규칙, 시나리오 17의 NUC 현장 차단. 명세 §11)

## 목표

봇과 독립된 관측·알림·외부 생존 감시를 세운다. 봇이 쓸 읽기 전용 접근, 경보 외부 수신자, 격리 작업 공간, 봇 자리 Application을 봇 없이 준비하고 확인한다.

## 선행 조건

- T08a: Tailscale operator(Grafana 내부 Ingress를 같은 방식으로 낸다), AdGuard Home과 그 질의 로그의 출처 확인 결과(U32. 이탈 감시 방식의 입력), 새 Tailscale ACL((a)인지 (c)인지에 따라 이탈 시험 방법이 갈린다).
- T09: 새 Telegram 봇 토큰과 healthchecks ping URL의 ESO 전달, ESO·ClusterSecretStore(시나리오 6·7 경보 부분), `eso-homelab`의 시험용 client secret 장애 주입 절차(설계 E3 표 아래).
- 사람 작업(설계 E4b): healthchecks.io 새 체크(Period 5분, Grace 5분), 새 Telegram 봇의 수신 chat 확인, 시험 경보 승인.

## 입력

- 옛 저장소(`2d2054a`)에서 가져올 것(설계 E4b): P23 하위(vmsingle 메모리 설정, vmalert reload, Alertmanager 설정 해시, 외부 수신자 `continue: true` 선례), L30, L34~L36의 교훈, L39, AIOps 격리 교훈(B.8 끝), B.8 "E4" 함정 중 관측 부분.
- T08a의 U32 결과.

## 범위

### 관측 스택 (D-09, `platform/observability`)

- 관측 스택 (D-09). Alertmanager 외부 수신자 연결과 읽기 전용 조회 계정을 포함한다(아래). D-09 확정(사용자 2026-10-18, T05)대로 옛 계열 최소 구성이다: VictoriaMetrics single, vmalert, Alertmanager, Grafana, VictoriaLogs single + vector, node-exporter, kube-state-metrics. vmagent와 보조 수집기 4개, CI·메타·기판 룰은 두지 않는다.
- 구성별 설정(설계 C.3.7):
  - VictoriaMetrics single: vmsingle이 `-promscrape.config`로 직접 수집한다. 보존 30일, `-memory.allowedBytes` 절대값. `retention.maxDiskSpaceUsageBytes`는 엔터프라이즈 전용이라 보존 기간으로 제한하고, 단위는 values 주석에 적는다.
  - vmalert: `-configCheckInterval=30s`, 룰은 Git.
  - Alertmanager 0.34.1: 설정은 configMapGenerator 해시로 롤아웃한다.
  - Grafana: 대시보드는 Git provisioning, 플러그인 없음. 내부 Ingress `grafana`(T08a의 operator).
  - VictoriaLogs single + vector: 로그 14일. vector는 root여야 `/var/log/pods`를 읽으므로 privileged ns `observability`에 둔다. vector·VictoriaLogs는 limit에 백로그 여유를 둔다(OOM 결합 루프).
  - node-exporter(systemd 수집 켬) + kube-state-metrics. 호스트 유닛 실패를 node-exporter가 본다.
- 버전: Alertmanager 0.34.1, 나머지는 이 티켓 시작 때 정해 고정한다(U14).
- 핵심 룰(15개 안팎): Watchdog(항상 발화), TargetDown, KubePodCrashLooping, KubePodNotReady(15분), OOMKilled, NodeMemoryHigh, NodeFilesystemAlmostFull, NodeSystemdUnitFailed, ArgoCDAppDegraded·OutOfSync(30분, `argocd_app_info` 지표), ExternalSecretNotReady(ESO 지표), CNPGClusterNotHealthy, PGBackupStale(마지막 성공 백업 26시간 초과)·WALArchiveFailing, ValkeyBackupStale, KubeJobFailed, AdGuard tailnet 이탈(아래). 룰 작성 규칙 4줄은 설계 B.8 E4다. 룰마다 단위 시험을 둔다(`vmalert-tool unittest`, 형식 [미검증] U11. 안 되면 promtool 형식 또는 시험 경보 수동 확인).
- Argo CD notifications는 설정하지 않고 지표 경보로 대신한다(옛 webhook 방식이 토큰을 DEBUG 로그로 유출했다).

### 비AI 알림 (D-10, AC-P11)

- 봇과 독립된 비AI 알림 (D-10, AC-P11). D-10 확정(사용자 2026-10-18, T05)대로 homelab 알림용 새 Telegram 봇을 쓴다. 봇은 T09가 만들고 토큰을 Infisical `homelab`의 `/platform/alerting`에 등록한다. 옛 Telegram 봇과 토큰은 `mac-uptime-guard`를 처리하는 T22까지 그대로 두고 이 티켓에서 쓰지 않는다.
- Alertmanager 기본 receiver `telegram`(내장 `telegram_configs`)이 봇을 거치지 않고 보낸다. 토큰은 `bot_token_file`이고 `chat_id`는 비밀이 아니라 values에 둔다. 자동 HTML escape 위에 이중 escape를 하지 않는다. 전송 확인은 로그가 아니라 `alertmanager_notifications_total{integration="telegram"}`이다.
- 라우트 모양은 설계 C.3.7 예시다. 봇 자리 route 네 줄(`severity=~"warning|critical"` → `bot`과 `continue: true`, 이어서 같은 matcher → `telegram` 형제 route)은 주석으로 둔다. `continue: true`는 부모 receiver로 되돌려 보내지 않으므로, 봇 route를 켤 때는 Telegram 형제 route를 함께 켠다(T16b).

### 외부 생존 감시 (D-10, AC-P11)

- 외부 생존 감시 (D-10, AC-P11). Alertmanager Watchdog → healthchecks.io 새 체크(Period 5분, Grace 5분). healthchecks.io 계정은 재사용하고 체크는 새로 만든다(D-10, D-20).
- Watchdog 라우트는 `group_wait: 0s`, `group_interval: 1m`, `repeat_interval: 1m`이다. `repeat_interval`만 1m이면 기본 group_interval 5m이 실제 간격이 되어 여유가 Grace 5분뿐이다. receiver `healthchecks`는 `webhook_configs`의 `url_file`, `send_resolved: false`다. healthchecks.io 쪽 통지(이메일, Telegram)는 NUC를 거치지 않는다.
- Alertmanager webhook이 ping URL로 직접 보내는 구성은 [미검증] U10이다. 안 되면 옛 relay를 가드(연결 없이 반환하면 ping하지 않음)와 함께 작게 둔다. 옛 relay는 그 가드가 없어 dead-man이 영구 초록이 됐다.
- 옛 healthchecks 체크 `homelab-watchdog`는 T06에서 일시 정지돼 있고 재사용하지 않는다. 새 체크가 초록인 것을 확인한 뒤 옛 체크를 지우고, T06 자격 폐기 표의 `보류(D-10, T08b)` 줄(옛 ping URL. 재분해 전 표시는 `보류(D-10, T08)`)을 닫고 [../approvals.md](../approvals.md)에 남긴다(D-10, D-11 표, D-20). **2026-10-19 실제:** 옛 체크는 T06 중에 사용자가 일시 정지 대신 지웠고, T06 표의 그 줄도 `삭제됨`으로 닫혔다(approvals). 이 티켓은 새 체크만 만든다.
- 공개 경로 생존 확인용 두 번째 체크는 설계 C.3.7의 선택 항목이고 기본은 두지 않는다.

### AdGuard tailnet 이탈 감시 (D-08)

- AdGuard Home이 tailnet에서 조용히 빠져도 공용 서버가 답해 증상이 없다. 관측 스택에 "tailnet 출처 질의가 1시간 0건이면 경보"를 둔다. 이 경보가 이탈을 잡는 유일한 장치라 실제 발화 시험을 완료 조건에 둔다.
- 질의 로그를 세는 방식은 이 티켓에서 T08a의 U32 결과로 정한다(설계 C.3.7 제안: 작은 CronJob이 AdGuard API를 읽어 지표를 내거나 healthchecks 체크를 ping). servicelb MASQUERADE로 모든 질의가 svclb 파드 IP 하나로 보이면 출처로 가를 수 없으므로, hostNetwork로 바꾸거나(T08a의 AdGuard 변경) 다른 방식(예: tailnet 쪽 기기의 주기 시험 질의)을 쓴다.
- 경보는 1시간 무질의가 지난 뒤 다음 평가 주기에 울린다.
- **AdGuard 정지 경보(AC-P6 한계 승인의 완화, T08a 2026-10-20):** 공유기가 보조 DNS로 넘어가지 않아 AdGuard Home이 멈추면 Tailscale 없는 LAN 기기의 DNS가 전부 끊긴다. 그래서 AdGuard Home 파드가 1분 넘게 Ready가 아니면 경보하고, 경보 문구에 런북 `docs/runbooks-public/nuc-dns-outage.md`를 넣는다. 핵심 룰의 KubePodNotReady(15분)로는 늦다. NUC 전체 정지는 외부 생존 감시가 잡는다. 발화 시험을 완료 조건에 둔다.

### 읽기 전용 접근 셋 (AC-P12, 설계 C.8)

- 읽기 전용 계정은 Kubernetes·관측·Argo CD 셋이다(AC-P12, 자리 배정은 명세 §4.4와 설계 E.3). Argo CD 계정은 재분해 전 T07 할 일 7에서 옮겨 왔다(T07 할 일 8에 이관 기록). 세 계정을 한 단계에서 확인한다.
- (a) Kubernetes: SA `bot-reader`(봇 자리 Application이 `target` ns에 만든다) + ClusterRole `homelab-readonly`(라벨 `homelab.ukyi.app/readonly`) + ClusterRoleBinding. get·list·watch만 준다: pods, deployments, replicasets, statefulsets, daemonsets, jobs, cronjobs, services, ingresses, events, nodes, namespaces, PV·PVC, CNPG clusters·databases·backups, ExternalSecret, Argo CD applications. secrets, configmaps, pods/log, pods/exec와 모든 쓰기는 없다. `view` 기본 역할은 configmaps·로그를 포함하므로 쓰지 않는다.
- (b) Argo CD: 로컬 계정 `bot-reader`(apiKey만). 정책은 `applications, get`, `applicationsets, get`, `projects, get`이고 sync·exec·logs는 없다. `policy.default`는 비운다. `argocd-cm`·`argocd-rbac-cm` patch(설계 C.3.3, `admin.enabled: "false"`)에 더한다.
- (c) 관측: Grafana 서비스 계정 `bot-reader`(Viewer). 대시보드 보기와 데이터소스 질의만 한다. 쓰기를 못 하는지는 [미검증] U12다. 안 되면 봇 읽기를 데이터소스 API 앞의 별도 읽기 프록시로 한다.
- 봇 ns의 NetworkPolicy는 클러스터 안에서 Grafana·Argo CD API만 더 열고 vmsingle·VictoriaLogs·Alertmanager API에는 닿지 않는다(Alertmanager API는 침묵 생성이 가능하다). Kubernetes API는 노드 로컬 경로라 NetworkPolicy로 막을 수 없어 읽기 전용 SA가 경계다.
- verb·roleRef를 막는 CI 검사(L30)는 전체 `ci`를 만드는 T10에서 본다.

### 경보 외부 수신자 (AC-P12, 설계 C.8)

- Alertmanager 라우트(`continue: true`) → receiver `bot`의 `webhook_configs.url_file` → 클러스터 안 봇 Service(공개 아님). 설계 C.3.7 예시의 주석 처리된 줄이다.
- Alertmanager는 보내기만 한다. 봇은 Alertmanager API에 NetworkPolicy로 닿지 않는다. 비AI 경로(Telegram)는 그대로 받는다.
- 이 티켓에서는 봇 자리 Application의 시험 ns `bot-slot-probe`에 시험 라벨로 둔 시험 수신기로 확인한다.

### 격리 작업 공간 (AC-P12, `platform/sandbox`, egress 프록시)

- 격리 작업 실행 공간 (AC-P12, 명세 §4.2). 기본 방식 확정(사용자 2026-10-18, T05): 설계 C.8 기본값이다. 운영·게시 자격(kubeconfig, GitHub 쓰기 키, Discord 토큰, SSH, 호스트 소켓)과 운영 네트워크(LAN, 클러스터 내부, Kubernetes API, tailnet, Infisical)에 닿지 못한다. 모델 자격만 별도 시크릿 범위로 받는다. egress는 허용 목록(모델 API, 코드 읽기용 `codeload.github.com`, 패키지 레지스트리)으로 제한한다. 봇이 이 공간을 쓰는 세부 방식은 D-14·D-15(확정(사용자 2026-10-18, T15))가 정했다: 작업자 전용 영속 쓰기 공간, 상주 작업자 하나(동시성 1), 컨테이너 포트 8080, `codeload.github.com`만 허용하는 코드 읽기(아래).
- 위치: ns `sandbox`(작업자) + ns `egress`(허용 목록 프록시). 프록시 이미지는 digest로 고정하고 버전은 이 티켓 시작 때 정한다(U14).
- 자격: SA 토큰 미마운트, RBAC 없음, hostPath·hostNetwork·호스트 소켓 없음. Secret은 Infisical `/apps/<bot>/worker`의 모델 자격 하나다. 작업자 전용 ClusterSecretStore `infisical-sandbox`(conditions는 `sandbox` ns 하나, `secretsPath` `/apps/<bot>/worker`)로 받는다. ExternalSecret은 `platform/sandbox`의 Git 매니페스트로만 생기고, sandbox 서비스 계정에는 ExternalSecret 생성 권한이 없다. 남는 위험: store identity `eso-homelab`은 Free에 경로 RBAC가 없어 `homelab` 프로젝트의 다른 경로도 읽을 수 있다.
- 영속 쓰기 공간(D-14, 설계 C.8 격리 행): `sandbox` ns에 작업자 전용 영속 쓰기 공간(`CODEX_HOME`용 PVC 하나)을 둔다. 모델 자격은 봇 전용 구독 계정의 Codex 인증 파일(`auth.json`)이고, Codex가 토큰을 갱신하면 이 파일을 다시 쓴다. ESO 한 방향 전달로는 갱신본을 지키지 못해 이 공간이 필요하다. Infisical `/apps/<bot>/worker`의 값은 첫 시드와 재시드용이고, 작업자는 영속 공간에 파일이 없을 때만 시드를 복사한다. 실제 시드는 T16b 전(모델을 처음 쓰는 단계 전) 사람 작업이다(설계 E9). 이 티켓은 시험 파일로 공간이 유지되는지만 본다. PVC 크기와 백업 여부는 설계에 없어 이 티켓에서 정한다(봇 저장소 `ARCHITECTURE.md` §10 열린 항목).
- 상주 작업자 자리(D-14, D-15): 작업자는 상주 파드 하나(Deployment replicas 1, 동시성 1)이고 컨테이너 포트는 8080이다. 작업 단위 파드는 두지 않는다. [제안] `strategy: Recreate`. RollingUpdate면 교체 중 두 파드가 같은 `auth.json`을 쓴다(설계 C.8).
- 네트워크: 기본 거부. egress는 `egress` ns 프록시 파드의 3128 하나뿐이고 DNS(CoreDNS 53)는 열지 않는다. 작업자 egress에서 DNS를 빼는 이유는 CoreDNS가 임의 이름을 공용 DNS에 재귀 질의해 이름에 실은 자격이 허용 목록 밖으로 나갈 수 있어서다. 작업자는 프록시를 고정 ClusterIP로 받는다(프록시 Service의 `spec.clusterIP`를 서비스 대역 안 고정값으로 선언, 작업자 env `HTTPS_PROXY=http://<프록시 ClusterIP>:3128`). 목적지 이름 해석은 프록시가 한다([미검증] U29. 안 되면 그 도구만 프록시 설정을 따로 주거나, `egress` ns에 허용 목록 도메인만 푸는 전용 DNS를 둔다).
- egress 허용 목록(D-15): 프록시는 모델 API, 코드 읽기용 `codeload.github.com`, 패키지 레지스트리만 통과시킨다. `github.com`·`api.github.com`·`gist.github.com`은 넣지 않는다. 작업자에는 GitHub 자격이 없다. 구독 인증(D-14)이 쓰는 모델·인증 호스트 목록은 [미검증]이고 T16b가 실측해 넣는다(설계 E9).
- 노드 로컬 경로(노드 IP의 6443·10250·22)는 NetworkPolicy로 못 막으므로, 작업자 파드 netns 안에서 init 컨테이너(NET_ADMIN, 그 컨테이너만)가 출력을 셋만 허용한다: loopback(`-o lo`), conntrack `ESTABLISHED,RELATED`, 프록시 ClusterIP:3128로 가는 새 연결. 본 컨테이너는 NET_ADMIN이 없다. 그래서 이 ns의 PSA는 privileged이고 파드는 Git(Argo CD)만 만든다. 이 방식은 [미검증] U13이다. 안 되면 호스트 전용 UID + nft(옛 AIOps 방식)로 물러난다(D-15, 확정(사용자 2026-10-18, T15)).
- 작업 전달은 봇 → 작업자 Service ingress 하나다. 이 허용은 봇 자리 Application에 있고 `platform/sandbox`에는 기본 거부만 있다.
- 남는 위험(쓰기 유출): 프록시는 CONNECT의 호스트 이름만 보므로 `github.com`을 허용하면 읽기와 쓰기를 가르지 못한다. 그래서 D-15(확정(사용자 2026-10-18, T15))로 코드 읽기를 `codeload.github.com` 압축본만으로 좁혔다(위 허용 목록). 패키지 레지스트리의 게시 API는 이 결정으로 줄지 않는다(설계 C.8).

### 봇 자리 Application (`platform/bot-slot`, 설계 C.8)

- 봇 자리 Application `platform/bot-slot`: root 아래 작은 Helm 차트, wave 1, `retry.limit: -1`(무제한)과 `retry.refresh: true`. 대상 ns를 만들지 않는다(`CreateNamespace` 없음).
- 대상 값 하나: `values.yaml`의 `target`(ns, 앱 라벨 `homelab.ukyi.app/app`의 값, 작업자 포트, 봇의 경보 수신 포트)이 모든 리소스의 대상과 출처를 정한다. 이 티켓에서는 시험 ns `bot-slot-probe`, 시험 라벨, 시험 작업자·시험 수신기의 포트다. 작업자 포트는 `platform/sandbox`의 작업자 컨테이너 포트와 같아야 한다.
- 경보 수신 포트의 Service: 공유 차트 values의 포트는 `port` 하나뿐이라 Alertmanager가 가리킬 경보 수신 포트(봇은 8081, D-15)의 Service가 따로 필요할 수 있다 [추측]. 이 Application이 `target`으로 함께 만들지는 이 티켓에서 정한다 [제안] (설계 C.8 봇 자리 Application).
- 담는 것: (1) `target` ns의 NetworkPolicy(egress를 `sandbox` 작업자, `observability` Grafana, `argocd` `argocd-server`로, ingress를 `observability` Alertmanager에서 경보 수신 포트로), (2) `sandbox` ns의 NetworkPolicy(`target` ns·라벨에서 작업자 포트로 오는 ingress), (3) SA `bot-reader`, ClusterRole `homelab-readonly`, ClusterRoleBinding, (4) `probe: true`일 때만 시험 ns `bot-slot-probe`의 Namespace(이 Application 안 앞 sync-wave)와 설계 C.4.5 네트워크 행을 손으로 옮긴 정책(기본 거부, DNS, 같은 ns, 인터넷 443).
- 손으로 옮긴 정책의 인터넷 443은 ipBlock `0.0.0.0/0`에 except `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`(tailnet)을 명시한다. IPv6 허용 줄은 두지 않는다. 공유 차트는 T10이 만들어 이 티켓이 쓸 수 없으므로 손으로 옮기고, 차트 egress의 같은 tailnet 제외는 T10이 둔다.
- 받는 쪽: `observability` ns에는 ingress NetworkPolicy를 두지 않는다. `argocd-server`는 공식 install.yaml의 정책이 모든 출처를 연다.
- 이 Application의 변경은 platform 변경이라 자동 병합 조건 밖이고 사람이 검토 후 병합한다. `target`을 봇 ns로 바꾸는 PR은 T16b가 봇 등록 PR보다 먼저 병합한다.

### 시나리오 6·7의 경보 부분 (T09가 넘긴 것)

- T09는 시나리오 6·7을 시험 ns에서 경보 없이 통과시켰다. 이 티켓은 ExternalSecretNotReady 경보와 Telegram 수신을 본다(설계 E3 표 아래 "E3에서 빼고 넘기는 확인").

## 필요한 자격

| 자격 | 위치 | 쓰는 곳 | 준비하는 티켓 |
|---|---|---|---|
| 새 Telegram 봇 토큰 | Infisical `homelab` `/platform/alerting` → ESO | Alertmanager `telegram` | T09(BotFather로 생성, 사람이 새 봇에게 먼저 메시지). 수신 chat 확인은 이 티켓 |
| healthchecks.io 새 체크 ping URL | `homelab`의 플랫폼 경로(설계 C.2 `/platform/<구성 요소>`) → ESO | Alertmanager `healthchecks` | 이 티켓(계정 재사용, 사람이 체크를 만들고 등록) |
| Grafana 관리자 자격 | `homelab` → ESO | Grafana | T09 |
| `eso-homelab` identity | ESO 부트스트랩 Secret | `infisical-sandbox`, 시나리오 6·7 장애 주입 | T09. 시험용 두 번째 client secret은 이 티켓에서 사람이 발급·폐기(승인 기록) |
| 작업자 모델 자격 | `homelab` `/apps/<bot>/worker` → `infisical-sandbox` | 작업자 파드(영속 공간에 파일이 없을 때만 시드로 복사) | 실제 값(봇 전용 구독 계정의 시드 `auth.json`, D-14)은 T16b 전(모델을 처음 쓰는 단계 전) 사람 작업(명세 §11 모델 행, 설계 E9). 이 티켓은 시험 값만 |

- Grafana SA `bot-reader` 토큰은 준비 확인(`GET /api/search`, `POST /api/dashboards/db`)에 쓰고 이 티켓에서 만든다. 봇이 쓸 토큰의 보관 위치는 설계에 없다.
- 옛 Telegram 봇 토큰은 쓰지 않는다(`보류(D-10, T22)`).
- 사람: healthchecks.io 콘솔(새 체크, 옛 `homelab-watchdog` 삭제), NUC sudo(이탈 시험의 임시 규칙), NUC 현장 접근(시나리오 17).

## 제약

- 외부 변경(감시·알림 계정, 체크 생성·삭제, 시험 경보, client secret 발급·폐기)은 사람 승인 뒤에 하고 [../approvals.md](../approvals.md)에 기록한다 (AC-X2).
- 운영 ESO client secret은 폐기하지 않는다. 장애 주입은 시험용 두 번째 client secret으로만 한다.
- 옛 Telegram 봇과 토큰은 T22까지 쓰지도 지우지도 않는다(D-10).
- 이 티켓은 T10의 공유 차트와 전체 `ci`를 쓰지 않는다.
- 시크릿 값은 출력하지 않는다. 같은지 비교할 때는 `sha256sum` 결과만 본다.

## 완료 조건

- 시나리오 16(비AI 경보), 17(외부 감시)을 통과한다.
- 시나리오 6·7의 경보 부분(T09가 넘긴 것)을 통과한다.
- "tailnet 출처 질의 1시간 0건" 경보의 실제 발화 시험을 통과했다(아래 검증).
- AdGuard 정지 경보(AdGuard Home 파드 1분 넘게 Ready 아님, 경보 문구에 런북 `docs/runbooks-public/nuc-dns-outage.md`)의 발화 시험을 통과했다. 정지는 LAN DNS 전체 장애라 시험 창을 짧게 잡는다(AC-P6 한계 승인, T08a 2026-10-20).
- 설계 C.8의 읽기 전용 접근(CI 검사 L30은 T10)·경보 외부 수신자·격리 작업 공간 준비 확인을 통과한다(D-14 영속 공간 유지와 상주 작업자 모양, D-15 허용 목록 확인 포함. 설계 E4b).
- 핵심 룰 단위 시험을 통과한다.
- 새 체크가 초록이 된 뒤 옛 healthchecks 체크를 지웠고, T06 자격 폐기 표의 그 줄(옛 ping URL, `보류(D-10, T08b)`)이 닫혔고, approvals에 기록돼 있다. (2026-10-19 T06 중 사용자가 먼저 지웠다. 이 항목은 그 approvals 기록과 콘솔에 옛 체크가 없음을 보는 것으로 닫는다)

## 검증

- 시나리오 16: 봇이 없는 이 시점에 `kubectl -n observability exec deploy/alertmanager -- amtool alert add alertname=PlatformTest severity=warning --alertmanager.url=http://localhost:9093`. 테스트 경보가 봇 없이 Telegram에 2분 안에 도착하는지와 수신 시각, `alertmanager_notifications_total{integration="telegram"}` 증가, `alertmanager_notifications_failed_total{integration="telegram"}` 불변을 확인한다(Grafana 또는 vmsingle API).
- 시나리오 17: NUC 네트워크를 물리적으로 끊거나 전원을 끈다(원격 접속이 끊기므로 현장에서). Period + Grace(10분) 뒤 healthchecks.io가 down으로 바꾸고 NUC를 거치지 않는 경로(이메일, Telegram 연동)로 알리는지, 복구 뒤 up 알림이 오는지 대시보드와 이벤트 기록, 수신 시각으로 본다.
- 시나리오 6·7 경보 부분: 시험 ns에 없는 키를 가리키는 ExternalSecret을 두고, 또 T09의 시험용 client secret 장애 주입으로 ESO 인증을 잠시 끊어(승인 기록) ExternalSecretNotReady 경보가 Telegram에 도착하는지 본다. 부트스트랩 Secret을 원래 client secret으로 되돌린 뒤 resolved와 시험 ns 삭제를 확인한다.
- 이탈 경보 발화 시험: AdGuard Home이 tailnet 질의를 받지 못하는 상태를 감시 방식(T08a의 U32 결과)에 맞춰 tailnet 경로만 끊어 만든다. D-11 (a)라 NUC는 태그 없는 기기이고 `autogroup:self:*`가 모든 포트를 연다. 그래서 사람이 sudo로 `iptables -t raw -I PREROUTING -i tailscale0 -p udp --dport 53 -j DROP`(tcp도 같이)를 임시로 넣고 시험 뒤 지운다. raw PREROUTING은 hostPort DNAT보다 먼저라 svclb 경로까지 끊긴다(형식 미검증). T08a에서 (c)로 바꿔 NUC를 `tag:nuc`로 태그했으면 정책 사본을 남기고 `tag:nuc:53` 규칙을 뺀 정책을 apply한다(승인 기록). 그 동안 Tailscale 기기는 공용 서버로 해석한다. 1시간 무질의 뒤 다음 평가 주기 안에 Telegram 경보가 오는지 확인하고, 규칙이나 정책을 되돌린 뒤 resolved를 확인한다. 룰 논리는 단위 시험으로 따로 본다.
- 핵심 룰: `vmalert-tool unittest`(형식 미검증, U11).
- 외부 생존 감시: 새 체크가 초록(up)인 것을 healthchecks.io에서 확인한 뒤 옛 `homelab-watchdog`를 지운다. (2026-10-19 T06 중 이미 지워졌다)
- 읽기 전용 접근(설계 C.8): `kubectl auth can-i --as=system:serviceaccount:bot-slot-probe:bot-reader list pods -A` → yes, 같은 주체로 `get secrets -A`, `get pods --subresource=log -A`, `create deployments -n app-smoke` → no. `argocd admin settings rbac can bot-reader get applications '*/*'` → Yes, `sync` → No(argocd-rbac-cm 오프라인 평가). Grafana 토큰으로 `GET /api/search` → 200, `POST /api/dashboards/db` → 403.
- 경보 외부 수신자(설계 C.8): `amtool config routes test ... severity=warning` → `bot` 포함, `amtool alert add alertname=BotRouteTest severity=warning` → 시험 수신기 로그 수신 + `alertmanager_notifications_total{integration="webhook"}` 증가 + Telegram도 수신.
- 격리 작업 공간(설계 C.8, 시험 파드):
  - 안에서 `curl -m 5`로 `https://10.43.0.1`, `https://<노드 IP>:6443`, `<노드 IP>:22`, 공유기 IP, tailnet 주소, `https://app.infisical.com` → 모두 실패.
  - `nslookup example.com` → 실패(DNS 차단), `nc -z -w 3 <CoreDNS ClusterIP> 53` → 실패.
  - `HTTPS_PROXY`만 둔 채 `curl -sI https://<허용 도메인>` → 연결(이름 해석은 프록시), `curl -x http://<프록시 ClusterIP>:3128 https://<허용 밖 도메인>` → 프록시 거부.
  - D-15 허용 목록: `HTTPS_PROXY`만 둔 채 `curl -sfo /dev/null https://codeload.github.com/ukyi-app/<public 시험 저장소>/tar.gz/<SHA>` → 성공, `https://github.com`·`https://api.github.com`·`https://gist.github.com` → 프록시 거부.
  - D-14 영속 공간: 시험 작업자가 `CODEX_HOME` 볼륨에 시험 파일을 쓰고 파드를 지운 뒤 새 파드에서 같은 내용이 남는다. `kubectl -n sandbox get deploy <작업자> -o jsonpath='{.spec.replicas} {.spec.strategy.type}'` → `1 Recreate`([제안] 값을 쓴 경우).
  - 시험 작업자 파드가 HTTP를 받는 상태에서 안에서 `curl -sf http://127.0.0.1:<포트>/` → 성공(loopback 허용).
  - 봇 자리 시험 파드(`bot-slot-probe`, 시험 라벨)에서 `curl -sf http://<작업자 Service>.sandbox:<포트>/` → 성공(응답 패킷이 `ESTABLISHED` 허용으로 나감), Grafana·Argo CD API → 연결, vmsingle·Alertmanager API → 실패. 같은 라벨이 없는 파드에서 작업자 Service → 실패.
  - `/var/run/secrets/kubernetes.io/serviceaccount` 없음. `kubectl auth can-i --as=system:serviceaccount:sandbox:default list secrets -n sandbox`와 `create externalsecrets.external-secrets.io -n sandbox` → 둘 다 no.
  - 사람이 sandbox ns에 만든 시험 ExternalSecret이 `infisical-platform`이나 `infisical-apps`를 가리키면 conditions로 동기화 거부.
  - 모의 비밀 읽기·임의 외부 쓰기·운영 변경 거부를 실측한다(AIOps 교훈).
- `kubectl get clustersecretstore`에서 `infisical-sandbox`를 포함한 셋이 모두 `Ready=True`다.

## 되돌리는 방법

- 클러스터 쪽(`platform/observability`, `platform/sandbox`, `platform/bot-slot`, Argo CD 계정 patch)은 revert PR로 되돌린다.
- healthchecks 새 체크는 지우지 않고 일시 정지한다. 옛 체크 삭제는 새 체크가 초록인 것을 확인한 뒤에만 한다.
- 이탈 시험의 iptables 임시 규칙은 시험 뒤 지운다. 정책을 바꿨으면 남겨 둔 정책 사본으로 되돌린다.
- 장애 주입은 부트스트랩 Secret을 원래 client secret으로 되돌려 복구한다. 시험용 두 번째 client secret은 폐기된 채 남긴다.
- 되돌리기 실행도 [../approvals.md](../approvals.md)에 기록한다.
