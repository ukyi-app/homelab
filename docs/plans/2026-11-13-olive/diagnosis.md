# 올리브의 진단과 근거 등급

진단 작업자(O11), 코드 작성 작업자(O13), 경보로 스스로 시작(O16), PR 자동 게시(O15)의 구현 기준이다. 결정의 기준은 `spec.md` §5.1이다. 이 문서는 그 결정을 조회·메모·판정·게시 순서로 풀어 쓴다. Discord 글의 모양은 `discord.md`를 따른다.

- 상태: 구현 전. D-34(근거 등급제)와 D-35(읽기 목록에 인증서·백업 예약 추가)는 관리자 결정이고, §7의 여덟 항목은 기본값(관리자 미확정)이다. 결정에서 따라 나온 구현 설계는 [추론]으로 구분한다.
- 표시: [확인] 저장소의 선언·코드·런북을 읽은 것, [추론] 그 근거에서 낸 설계, [미확인] 실제로 돌려 봐야 아는 것. 선언 확인은 운영 적용 확인이 아니다.
- 근거: 2026-11-14에 원격 main과 일치를 확인한 `homelab`의 `5f85a642b09364606b6990aa73af9927df23dbbd`. 아래 저장소 경로와 줄 번호는 이 revision 기준이다. 계획 참조는 이 폴더의 문서를 따른다.
- 예시의 시각·수치·대상·근거 ID는 모두 가짜다. 예시 영수증은 실제 판정에 쓸 수 없다.

## 1. 진단 한 번의 흐름

아래는 [추론] 구현 순서다. 권한·시작 여부·예산·등급·게시는 모델 밖 코드가 정한다.

| 단계 | 누가 | 입력 | 출력 |
|---|---|---|---|
| 경보 접수 | 현관 | Alertmanager 경보 묶음 | 출처·모양·크기를 검사한 경보 이벤트와 접수 영수증 |
| 시작 판정 | 감독 | 경보, 장애 색인, 현관이 확인한 PR 상태, 정지 상태·횟수 | 시작 / 진행 중 진단에 붙임 / 알림만 / 무시 |
| 조사 계약 | 오케스트레이터 → 감독 | 경보·대상, 지도, 관련 런북 | 기준 시각·고정 Git SHA·차트 revision·질문·예산·완료 조건 |
| 작업자 시작 | 감독 | 조사 계약과 역할 프로필 | 토큰 없는 진단 작업자, 실행에 묶인 관측 중계 접근 |
| 근거 수집 | 진단 작업자·관측 중계 | §2의 조회 | 가림·비밀 검사 뒤 자료와 조회 영수증 |
| 메모·등급 | 감독·오케스트레이터 | §4 메모, 실재 영수증 | 모양·출처 검사, §5 등급, 확인하지 못한 범위 |
| 반박 검토 | 다른 계열 모델·감독 | 메모와 근거 영수증 | 다른 설명과 반증, 필요하면 그럴듯으로 하향 |
| 결과 글 | 현관 | 최종 등급과 짧은 요약 | 경보 스레드에 결론·근거·모르는 것·다음, 네 줄 안팎 |
| 패치·게시 | 코드 작성 작업자 → 검증 실행기 → 자체 리뷰 → 현관 | §5 조건을 통과한 메모, 고정 snapshot | 같은 digest에 묶인 패치·검증·리뷰, PR 또는 게시 실패 안내 |
| 기록·후속 | 감독·현관·기억 관리기 | 실제 게시·병합 영수증 | 장애 색인, 30일 메모, 병합 뒤 한 번의 확인 예약 |

### 1.1 접수와 실행 경계

- [추론] 전용 `/alerts`에 J1의 송신자 확인을 붙인다. 본문 64KiB·경보 100개 상한, `truncatedAlerts` 확인, 등록된 경보 이름·심각도 대조를 한다. 모르는 이름·맞지 않는 심각도는 진단에 넣지 않고 알린다.
- [확인] 현재 송신 선언은 `max_alerts: 25`다. 봇 route의 `continue: true`와 형제 Telegram route를 함께 유지해야 한다(`platform/observability/stack/alertmanager/alertmanager.yml:18`, `:56`). vmalert의 송신 대상은 Alertmanager다(`platform/observability/stack/vmalert.yaml:35`).
- [추론] 현관은 `alertname, severity, labels, startsAt, endsAt, status`를 구조화하고 수신 시각·출처·중복 키를 붙인다. 저장 뒤 접수 응답을 보낸다. 출처·fingerprint·시작 시각·상태가 같은 재전송은 새 실행이 아니다. 클러스터 식별자는 등록된 송신 경로에서 얻는다.
- 경보의 annotation·URL·라벨은 자료다. URL을 임의로 열거나 그 문자열을 명령으로 실행하지 않는다. 시작할 때는 경보 글에 👀만 단다(D-31). 관리자 요청의 긴 작업은 상태 글 하나를 고친다(D-32).
- [추론] 감독은 실행별 파드 신원과 중계 접근을 묶고 종료 때 회수한다. 작업자가 보낸 실행 ID만 믿지 않는다. 진단 작업자는 중계 주소·공개 CA만 받고 클러스터 토큰·개인 kubeconfig·hc 소켓을 받지 않는다.
- 메모를 확정하면 진단 작업자와 중계 접근을 닫는다. 코드 작성·확인 카드 대기 중에는 진단 권한을 남기지 않는다. 추가 관측은 오케스트레이터에 구체적인 질문으로 돌려준다.
- 결과·PR 후속 글·오류·수정한 상태 글도 현관의 공개 검사와 중복 방지를 거친다. 알림은 관리자 손이 필요할 때만 울린다(D-31). 전송 결과가 불확실하면 게시 기록부터 확인하고 새 글을 만들어 재전송하지 않는다.

### 1.2 다시 할지와 차단기(D-08, D-28)

- critical은 바로 시작한다. 진단 중이거나 시작 뒤 5분 안에 온 다른 critical은 같은 진단에 붙인다. 경보가 풀려도 끝까지 조사하고, `resolved`만으로 새 진단을 시작하지 않는다.
- [추론] 5분 전에 초안을 끝냈으면 남은 묶음 시간은 모델 없이 기다린다. 새 경보가 오면 같은 실행 ID·남은 예산으로 보완한다. PR 작성·카드 대기는 진단 중으로 세지 않는다.
- 열린 올리브 PR이면 한 번 알리고 재진단하지 않는다. 관리자 조치로 끝났으면 그 조치를 다시 알린다. 수정 병합 뒤 재발이면 다시 진단한다. 원인 미상이면 1시간 뒤에도 울리거나 다시 울릴 때 한 번 더 진단한다.
- 경보별 하루 3번·전체 하루 5번이다. 한 경보의 상한을 묶음 합류로 우회하지 않는다. 상한에 닿으면 알림만 한다. 날짜·묶음 계산은 J6·J7, 메모 만료와 병합 없이 닫힌 PR은 J8·J9를 따른다.
- warning은 알림만, none은 무시한다. 관리자가 부탁한 진단은 자동 횟수에 세지 않는다. 이 요청도 읽기 범위·실행 예산·비상 정지를 우회하지 않는다.
- 올리브 자신·모델 한도·삭제 원장 경보는 묶음에서도 빼고 Telegram으로만 보낸다. 자동 진단의 일시 중지는 `homelab` CLI 전용이며 대화·수동 진단은 유지한다.
- [추론] 실행 예약·횟수·PR 상태·확인 예약은 재시작 뒤 복원한다. 계정 전환이나 추가 경보가 예산을 초기화하지 않는다. 관측 실패를 서비스 장애나 원인 미상 재진단 허가로 바꾸지 않는다.

## 2. 진단 작업자가 보는 순서

### 2.1 공통 순서 [추론]

1. 경보 시작 시각 T와 조사 시각 N을 나눈다. 지도에서 네임스페이스·워크로드·Application·설정 파일을 찾고 원본을 다시 읽는다. 지도 생성기(O19) 전에는 저장소를 직접 읽는다. 이전 30일 메모는 필요할 때만 찾는 검증 안 된 참고다.
2. 해당 파드와 상위 워크로드를 본다. generation·observedGeneration, 준비 수, conditions, 재시작 수, 종료 reason·exitCode·시각, imageID를 읽는다. 현재 누적 재시작 수를 최근 장애 횟수로 단정하지 않는다.
3. 해당 대상의 이벤트부터 좁혀 읽고 Service·PVC/PV·Node·ExternalSecret·CNPG 상태로 넓힌다. 이벤트가 없다는 이유로 장애가 없었다고 하지 않는다.
4. VictoriaLogs에서 `[T-10분, min(T+10분,N)]`을 먼저 읽는다. namespace를 지정하고 pod·container로 좁힌다. 파드 교체가 있었으면 이전 이름과 시각을 찾는다. 오류만 골라 정상·회복 로그를 놓치지 않는다.
5. 경보의 원래 식을 T와 N에서 먼저 조회하고 관련 지표의 추세를 본다. `up`과 시계열 부재도 확인한다. 빈 결과를 0으로 바꾸지 않는다.
6. Argo Application의 sync·health·revision·operationState와 고정 Git 설정을 대조한다. 관련 main 이력은 최근 24시간·20개부터, 필요하면 7일·50개까지 읽는다. 커밋이 시간상 앞섰다는 이유만으로 원인이라고 하지 않는다.
7. 관찰 사실, 가설, 배제한 다른 원인, 못 읽은 범위, PR 후보 또는 관리자 조치를 적는다. 같은 결과만 반복되거나 상한에 닿으면 멈춘다.

[확인] Vector는 `namespace,pod,container`를 만들고 `kubernetes`·`file`을 지운다. 앱 로그의 message를 별도 JSON으로 파싱하는 선언과 호스트 journal 수집 선언은 없다(`platform/observability/stack/vector/vector.yaml:2`). 기본 지표 수집 간격은 30초다(`platform/observability/stack/vmsingle/scrape.yaml:4`).

[확인] 앱 values는 main에서 읽어 Application의 `valuesObject`에 넣지만 차트는 태그를 쓴다(`platform/appsets/apps/files/applicationset.yaml:27`, `:60`, `:85`). [추론] 차트 revision 하나로 values의 main SHA를 확정하지 않는다. 현재 source와 실행 중 source의 동일 여부는 가림 전 중계 코드가 비교하고 영수증으로 준다.

### 2.2 스스로 진단하는 심각 경보 아홉

조건과 critical 표시는 [확인], 첫 조회는 [추론]이다. 근거 열의 경로는 `platform/observability/stack/vmalert/rules/` 아래다.

| 경보 | 선언의 조건 | 첫 조회와 구분할 것 | 근거 파일:줄 |
|---|---|---|---|
| `AdGuardDown` | available < 1 또는 시계열 없음, 1분 | `adguard` 파드·Deployment·init 종료 이유·이벤트, kube-state-metrics `up`. DNS 중단과 수집 중단을 구분 | `adguard.yaml:8` |
| `AdGuardTailnetQueriesMissing` | 현재 svclb 질의·시작 시각 중 최신값 대비 파일 시각 1시간 초과, 또는 벽시계 6시간 초과이며 리더 데이터 있음 | `kube-system`의 svclb 파드·컨테이너 시작 시각, querylog 수집 `up`, 원래 식. client 결합은 지표 저장소 안에서 하고 주소는 가림 | `adguard.yaml:40` |
| `NodeFilesystemAlmostFull` | ext4/xfs/btrfs 여유 < 10%, readonly=0, 15분 | mountpoint별 avail·size·readonly, Node DiskPressure, PVC/PV 배치. 선언 용량은 실제 사용량이 아님 | `core.yaml:70` |
| `CloudflaredTunnelDown` | 최근 2분 연결수 최댓값 < 1 또는 지표 없음, 3분 지속 | `cloudflared` 파드·재시작·ExternalSecret·로그, 연결수와 `up`. 토큰 값·외부 계정은 읽지 않음 | `platform.yaml:37` |
| `CNPGClusterNotHealthy` | namespace·cluster별 collector up 최댓값 < 1, 5분 | `database/pg` Cluster·파드·PVC·이벤트·DB/plugin 로그, `up`. 지표 자체가 없으면 이 식은 조용할 수 있음 | `platform.yaml:54` |
| `PGBackupStale` | 마지막 성공 백업이 26시간 초과, for 없음 | Backup·ScheduledBackup 상태와 시작/끝 시각(D-35), Barman 성공 timestamp·plugin 로그·ExternalSecret. ObjectStore 설정은 Git에서 | `platform.yaml:63` |
| `WALArchiveFailing` | 마지막 실패 시각 > 마지막 성공 시각, 10분 | 두 timestamp와 CNPG/plugin 상태·로그. 실패 없음(-1), 회복, 디스크·연결·자격 가설을 구분 | `platform.yaml:71` |
| `CertificateExpiringCritical` | 양수 만료 timestamp 기준 남은 시간 < 1일 | Certificate의 Ready 조건과 갱신 시각, CertificateRequest·Order·Challenge의 실패 이유, Issuer 상태(D-35), 만료 지표, cert-manager 파드·이벤트·로그. Secret은 권한 밖 | `platform.yaml:126` |
| `TailnetTLSExpiringCritical` | 남은 시간 < 7일, 현재 tailscale Ingress와 tls_host 일치 | 가린 Ingress 대상, 프록시·operator 로그, 원래 지표 식. TLS 접속 시험·외부 API·재시작은 하지 않음 | `platform.yaml:162` |

[확인] `PGBackupStale`은 CNPG의 옛 timestamp 대신 Barman Plugin 지표를 쓴다(`platform.yaml:62`). 백업 일정은 Git에 매일 03:00 KST로 선언돼 있다(`platform/cnpg/cluster/templates/scheduledbackup.yaml:1`). `database/pg`의 이름은 `platform/cnpg/cluster/templates/cluster.yaml:4`에서 확인했다.

[확인] 나머지 critical 세 개는 `HomelabBotLedgerDiskNotMounted`, `HomelabBotLedgerDiskReadOnly`, `HomelabBotLedgerFailed`다(`bot.yaml:224`, `:240`, `:254`). D-28에 따라 자동 진단에서 제외한다. 여기서 `platform.yaml`·`bot.yaml`은 위 표와 같은 경보 규칙 폴더다.

## 3. 관측 중계

### 3.1 허용 리소스와 경로

[확인] 아래 표의 앞 여섯 줄은 `platform/bot-slot/templates/rbac.yaml:23`의 `homelab-readonly`와 같다. 그 목록에는 인증서와 백업 예약이 없어서 D-35가 마지막 두 줄을 더했다. [추론] 새 진단 전용 SA와 역할은 **get·list만** 준다. 기존 역할의 watch는 복사하지 않고, `homelab-readonly` 자체는 고치지 않는다(D-05, D-20, D-35).

| API 그룹 | 허용 리소스 |
|---|---|
| core | pods, services, events, nodes, namespaces, persistentvolumes, persistentvolumeclaims |
| apps | deployments, replicasets, statefulsets, daemonsets |
| batch | jobs, cronjobs |
| networking.k8s.io / events.k8s.io | ingresses / events |
| postgresql.cnpg.io | clusters, databases, backups |
| external-secrets.io / argoproj.io | externalsecrets / applications |
| cert-manager.io (D-35) | certificates, certificaterequests, issuers, clusterissuers |
| acme.cert-manager.io / postgresql.cnpg.io (D-35) | orders, challenges / scheduledbackups |

[추론] 아래 경로를 파싱하고 group·version·resource·scope·이름을 대조한다. 버전은 배포 때 신뢰된 discovery로 확인한다. nodes·namespaces·persistentvolumes·clusterissuers는 클러스터 범위이고 나머지는 전 네임스페이스 list가 가능하다.

```text
/api/v1/<resource>[/<name>]
/api/v1/namespaces/<namespace>/<resource>[/<name>]
/apis/<group>/<version>/<resource>[/<name>]
/apis/<group>/<version>/namespaces/<namespace>/<resource>[/<name>]
```

네임스페이스 없는 경로의 `[/<name>]`은 클러스터 범위 리소스에만 받는다. 네임스페이스에 속한 리소스를 네임스페이스 없이 이름으로 읽는 요청은 거절한다.

- 받는 것: HTTP GET, 검증된 `labelSelector, fieldSelector, limit, continue, resourceVersion, resourceVersionMatch, timeoutSeconds`. discovery(`/api`, `/apis`, 허용 그룹·버전 경로, `/version`)는 허용 목록으로 만든 최소 정보만 준다. JSON 객체를 가린 뒤 반환하고 `kubectl get -o json`을 기본으로 한다.
- 거절하는 것: 목록 밖 리소스, 모든 쓰기 메서드, `watch` 매개변수·경로, 모든 하위 리소스(`log, exec, attach, portforward, proxy, status, scale, token`), stream·upgrade, OpenAPI 전체·인증 API. `get --raw`도 같은 검사다.
- Secret·ConfigMap뿐 아니라 ObjectStore·EndpointSlice·NetworkPolicy·ApplicationSet도 허용하지 않는다. 필요하면 Git·지표로 대조하고 부족한 부분을 알린다.
- 이중 인코딩·점 경로·인코딩된 슬래시·중복 query key·남는 경로·임의 Host·절대 URL을 거절한다. upstream 리다이렉트를 따르지 않는다. 응답의 종류·대상도 검사하고 Table·protobuf로 가림을 우회하지 못하게 한다.
- `continue`는 실행·경로·selector·만료에 묶인 중계 커서다. kubectl 객체 본문은 유지하고 가림·불완전성·영수증은 별도 감독 경로로 전한다.
- 로그는 `/logs/query`·`/logs/hits`에서 고정 VictoriaLogs `/select/logsql/query`·`/select/logsql/hits`로만 간다. 지표는 `/metrics/query`·`/metrics/query_range`에서 고정 vmsingle `/api/v1/query`·`/api/v1/query_range`로만 간다.
- 질의식은 자유롭게 만들 수 있다. 고정 조회 카탈로그로 제한하지 않는다. 임의 URL·tenant·header 전달, tail·export·federate·전체 series 나열·관리·쓰기 경로는 닫는다. [확인] 직결 시 쓰기 경로까지 닿는 함정은 `platform/observability/stack/vmauth/auth.yaml:1`에 기록돼 있다.

### 3.2 가릴 칸

처리는 [추론]이고 J2를 따른다. 근거 파일은 그 칸이나 중첩 사본이 실제 선언에 있다는 [확인]이다. 평문 비밀을 발견했다는 뜻은 아니다.

| 칸 | 처리 | 저장소 근거 파일:줄 |
|---|---|---|
| Pod·모든 PodTemplate의 containers/initContainers/ephemeralContainers `env[].value` | 값 전체 가림. 이름·valueFrom 참조는 검사 뒤 남김. 참조를 따라 Secret을 읽지 않음 | `platform/charts/app/templates/_helpers.tpl:112` |
| `command`, `args`, probe/lifecycle `exec.command`, HTTP header 값 | 전체 가림. 배열 길이·가림 표시만 남기고 명령은 고정 Git에서 확인 | `platform/adguard/templates/deployment.yaml:36`, `platform/go/templates/deployment.yaml:37`, `platform/charts/app-data/templates/valkey.yaml:142` |
| 모든 깊이의 `metadata.annotations`, `managedFields` | annotation은 키만 남김. last-applied 설정 사본도 가림. managedFields 제거 | `platform/go/templates/service.yaml:16`, `platform/go/templates/deployment.yaml:18`, `platform/root/templates/cnpg-cluster.yaml:38` |
| Argo source/sources·comparedTo·operation·history의 Helm values/valuesObject/parameter 값·plugin env·inline 설정 | 중첩 사본까지 전체 가림. repoURL 자격·query 제거. path·chart·revision은 검사 뒤 남김 | `platform/appsets/apps/files/applicationset.yaml:85`, `platform/root/templates/observability.yaml:24`, `docs/runbooks-public/apps.md:13` |
| ExternalSecret `target.template.data`, templateFrom inline literal·template annotation | 값 전체 가림. Ready·시각·reason·대상·참조 키 이름은 검사 뒤 남김 | `platform/charts/app/templates/externalsecret.yaml:49`, `:80` |
| Challenge의 `spec.key`, `spec.token`(D-35) | 값 전체 가림. 상태·reason·대상 도메인은 검사 뒤 남김 | cert-manager CRD의 칸. 저장소에는 선언이 없고 발급 중에만 생긴다 [미확인: 실제 CRD 버전의 칸 이름은 O11에서 확인] |
| 이벤트 message/note, 상태·종료 message, 로그 전체 필드, 지표 label, 모든 문자열·JSON key | 디코딩 뒤 비밀 검사. 자격·이메일·tailnet 이름·Tailscale IP 가림. 같은 실행의 주소는 불투명 별칭으로 연결 | `platform/observability/stack/vmalert/rules/adguard.yaml:43`, `platform/observability/stack/vmalert/rules/platform.yaml:144`, `.gitleaks.toml:23` |

알 수 없는 칸도 전체 응답 비밀 검사를 거친다. 파싱·검사 실패나 가릴 위치를 특정할 수 없는 응답은 통째로 막는다. 잘라 낸 조각만 검사하지 않는다. 별칭의 원문 해시를 공개하지 않고, 재조회는 중계가 발급한 대상 참조를 검증해 쓴다.

### 3.3 조회 상한 [추론, J3·J4 기본값]

| 대상 | 상한 |
|---|---|
| 공통 | upstream 동시 요청 1개, 질의 UTF-8 8KiB, upstream 5초·중계 전체 7초. 압축 해제 뒤 크기도 셈 |
| Kubernetes | 페이지 100개, 같은 조회 5페이지·500개. upstream 응답/객체 2MiB, 가림 뒤 페이지 256KiB. 초과는 불완전·상한 초과로 알림 |
| 로그 | 첫 창 20분, 최대 1시간·100줄·64KiB, 한 줄 2KiB. 최근 48시간 안에서 조회. 자름은 검사 뒤 표시 |
| 로그 hits | 최대 1시간, 간격 60초 이상·61버킷 이하·16KiB |
| 지표 | instant 100시계열·64KiB. range 기본 1시간·step 60초, 일반 최대 6시간. 긴 판단은 48시간·step 300초 이상. range 20시계열·총 10,000점·256KiB |
| 진단 한 번 | 작업자 시작부터 15분, 누적 200,000토큰(캐시 읽기·입력·출력 포함), 출력 12,000토큰, 관측 요청 60회·가림 뒤 누적 4MiB |

- 먼저 닿는 상한에서 멈춘다. 마지막 1분·출력 2,000토큰은 메모에 남긴다. 페이지·재시도도 세며 계정 전환·추가 경보로 늘리지 않는다. 자동 연장하지 않는다.
- start/end뿐 아니라 range selector·subquery·offset·`@`의 실제 참조 시각도 최근 48시간 안인지 검사한다. LogsQL 하위 질의에도 시간·stream 제한을 적용한다. 범위를 입증하지 못하는 구문은 거절한다.
- `limit=0`·음수·NaN·너무 작은 step을 거절한다. 출력 상한은 검색 비용 상한이 아니다. 시간 초과 시 upstream 취소를 확인하고 무조건 재시도하지 않는다.
- 하루 5회의 100만 토큰은 진단 역할만의 상한이다. 오케스트레이터·반박 검토·패치·자체 리뷰는 별도 역할 예산이며 전체 비용도 기록한다.

## 4. 진단 메모의 모양

[추론] 내부 교환은 JSON이다. 본문은 아래 **여섯 칸**만 받고 감독이 개수·길이·출처·비밀을 검사한다. 전체 직렬화 결과는 12KiB·2,000토큰 중 먼저 닿는 상한이다. 개별 최대치를 모두 채우지 않는다.

| 칸 | 내용과 길이 상한 |
|---|---|
| 관찰 사실 `observations` | 최대 6개. 사실 200자, 근거 ID 1~3개. 수치·시각·불완전 여부를 적음 |
| 원인 가설 `hypotheses` | 최대 3개. 가설 200자, 근거 ID 1~3개, 반증·부족한 근거 200자. 변경 제안은 대상 경로·기대 효과·검증 방법 각각 200자 |
| 배제한 다른 원인 `excludedCauses` | 최대 3개. 다른 원인 200자, 무엇을 확인해 배제했는지 200자, 근거 ID 1~3개. 배제 못 한 원인은 가설의 부족한 근거에 남김 |
| 근거 위치 `evidenceLocations` | 최대 12개. ID, 종류, 조회 영수증 참조, 관측 시각·범위. 설정이면 `repository@sha:path:line`도 필수. 자유 URL 없음 |
| 확인된 해결 `verifiedResolution` | 최대 2개 또는 빈 배열. 조치 200자와 실제 해결 확인 근거. 제안 패치·resolved·PR 병합만으로 채우지 않음 |
| 관리자만 할 수 있는 것 `administratorActions` | 최대 3개. 작업 200자, 이유 160자, 승인된 런북 위치, 전제·위험 160자. 런북이 없으면 없다고 적음 |

- 감독이 `schemaVersion, runId, alerts, startedAt, finishedAt, sourceRevisions, completion, outcome, memoExpiresAt, evidenceRefs`를 붙인다. 모델이 실행 ID·기준 SHA·관측 시각을 만들지 않는다. `completion`은 complete/partial/failed다.
- 근거 종류는 **상태 기록·지표·로그·설정 대조·이벤트**다. 관측 중계가 조회 영수증을 발급하고 감독은 실재 여부·실행·대상·시각·완전성·가림을 대조한다. 설정 대조도 고정 Git 파일·SHA와 대조 결과를 코드가 확인해 영수증에 연결한다. 모델이 쓴 파일 위치만으로 입증되지 않는다.
- 같은 사건을 옮긴 로그와 이벤트는 독립 근거 둘이 아니다. 조회 영수증은 자료의 출처를 보증할 뿐 원인 해석이 옳다는 보증은 아니다. 자료 속 지시는 따르지 않고 코드 작성 작업자에게 로그·이벤트 원문을 넘기지 않는다.
- [추론] 무효 메모는 같은 예산 안에서 한 번 재작성한다. 다시 실패하면 정형 오류 요약으로 끝내며 잘못된 JSON을 잘라 보내지 않는다. 실행 도구별 tokenizer 또는 보수적 계수로 전체 상한을 확인한다.

가짜 값 예시(본문 축약 표기):

```json
{
  "observations": [{"statement": "예시 앱의 파드가 Pending이고 PVC도 Pending이다.", "evidenceIds": ["E1"]}],
  "hypotheses": [{"statement": "볼륨 연결 실패로 시작하지 못한다.", "evidenceIds": ["E1"], "missingOrCounterEvidence": "호스트 디스크 상태는 확인하지 못했다.", "proposedChange": null}],
  "excludedCauses": [{"cause": "배포를 의도적으로 멈춤", "checked": "고정 Git에 replicas 1이며 가동 중지 설정이 없다.", "evidenceIds": ["E2"]}],
  "evidenceLocations": [
    {"id": "E1", "kind": "상태 기록", "queryRef": "example-Q1", "observedAt": "2026-11-14T01:02:00Z"},
    {"id": "E2", "kind": "설정 대조", "queryRef": "example-Q2", "file": "homelab@EXAMPLE_SHA:apps/example-app/values.yaml:1", "observedAt": "2026-11-14T01:03:00Z"}
  ],
  "verifiedResolution": [],
  "administratorActions": [{"action": "호스트 볼륨과 디스크 상태를 확인한다.", "reason": "파드 상태만으로 근본 원인은 확정하지 못한다.", "runbook": null, "preconditionOrRisk": "원인을 확인하기 전에 PVC나 데이터를 지우지 않는다."}]
}
```

이 예시는 원인을 입증한 두 갈래가 아니다. E2는 의도한 중지만 배제하므로 호스트 원인은 여전히 미확인이고 PR 없이 관리자 조치를 알린다.

보관은 D-22·D-27을 따른다. 도구 출력·CLI 기록은 받은 때부터 168시간, 메모·짧은 근거 묶음은 30일이다. 메모는 "검증 안 된 메모"이며 재요약으로 기한을 늘리지 않는다. 원문 SSD 사본도 같은 기한에 지우고 원문을 R2에 평문으로 넣지 않는다.

장애 색인은 경보·시각·실행 ID·PR 번호·결과 enum만 남긴다. 기존 enum `사람 몫`은 내부 식별자이고 보이는 글은 "관리자 조치 필요"다. 감사 1년에는 대상·기간·질의 digest·크기·거부 코드만 남기고 원시 질의·응답은 넣지 않는다. 모델 글을 영구 사실로 자동 승격하지 않는다.

## 5. 근거 등급제(D-34)

올리브가 스스로 고치려 할 때 적용한다. **관리자가 말로 시킨 변경에는 적용하지 않는다.** 그 변경은 D-29대로 한 줄 알리고 진행하되 보호 경로 확인 카드와 일반 검증은 유지한다.

### 5.1 조건과 행동

D-34·AC-27과 O11의 판정 조건을 다음처럼 적용한다. 등급은 **감독의 코드**가 근거 종류와 조회 영수증으로 매긴다. 모델이 적은 확신이나 숫자 확률은 판정 근거가 아니다.

| 단계 | 조건 | 행동 |
|---|---|---|
| 확실 | 원인이 기록에 직접 남았거나(종료 사유, 만료 시각 등), 설정만으로 오류가 입증되거나, 종류가 다른 독립 근거 둘이 같은 원인을 지지함. 어느 경우든 배제한 다른 원인 칸이 근거와 함께 차 있고 설명을 뒤집을 미해결 대안이 없음. 직접 기록도 정적 입증도 아닌 근거가 한 갈래뿐이면 아래 그럴듯을 적용(AC-27) | 다른 계열 모델의 반박 검토 뒤 패치·검증·자체 리뷰·PR. 보호 경로는 확인 카드 뒤 |
| 그럴듯 | 근거가 한 갈래뿐이거나, 배제하지 못한 원인이 남거나, 그럴 만한 반박이 나옴. 원인과 가능한 수정은 설명할 수 있음 | 진단을 알리고 "만들까요?". 관리자가 "만들어"라고 하면 제목에 가설 표시를 붙여 PR |
| 모름 | 원인을 설명할 유효한 근거가 부족하거나 관측 실패·모순으로 판단할 수 없음 | 조사 내용과 못 확인한 범위만 알림. PR 없음 |

배제한 다른 원인 칸이 비면 확실이 될 수 없다. 모델이 확실이라고 써도 조건이 모자라면 그럴듯 이하로 내린다. 직접 기록도 정적 입증도 아닌 한 갈래 근거만 있으면 PR 없이 질문으로 끝난다(AC-27). 직접 기록도 입증한 범위까지만 쓴다. 예를 들어 OOM 기록은 종료 이유이지 메모리를 올려야 한다는 증명이 아니다.

### 5.2 반박 검토와 게시

- 스스로 PR로 넘어가기 전에 다른 계열 모델이 메모·영수증으로 다른 설명을 찾는다. O13의 기본은 Codex다. 같은 계열 모델을 다른 계정으로 바꾼 것은 반박 검토가 아니다.
- 재조회가 필요하면 감독이 진단 작업자를 통해 D-05·D-20의 같은 범위와 상한으로 읽게 하고 반박 검토에 결과를 준다. 코드 작성·PR 리뷰 역할에 클러스터 접근권을 주지 않는다. 그럴 만한 반박이 나오면 감독이 그럴듯으로 내리고 자동 패치로 넘어가지 않는다.
- [추론] 반박 검토가 실패하거나 다른 계열 모델을 쓸 수 없으면 통과로 기록하지 않는다. 자동 게시를 멈추고 확인하지 못했다고 알린다. 반박 결과도 원인에 대한 최종 보증은 아니다.
- "만들어"는 해당 가설 PR을 부탁하는 말이다. 보호 경로 게시 승인 "올려"와 다르다. 현관은 관리자·스레드·대상을 확인하며 보호 경로면 별도 확인 카드(D-26·D-30)를 거친다. 카드 24시간·승인 뒤 실행 10분, 내용·대상·보호 경로 변경 시 무효 규칙은 그대로다.
- 대상 저장소·파일·키·base SHA·기대 효과·검증 방법이 있어야 패치를 만든다. 자기 저장소 `homelab-bot`·`olive`는 패치도 만들지 않는다(D-25). 같은 원인의 열린 PR은 다시 만들지 않는다.
- 네트워크 없는 고정 검증과 자체 리뷰를 통과한 digest만 현관이 게시한다. main이 바뀌면 충돌과 근거 유효성을 다시 본다. 근거 없는 자원 증설·경보 임계값 완화·보안 제한 해제로 경보를 잠재우지 않는다.
- PR 본문에는 **근거, 배제한 원인, 병합 뒤 확인할 것, 되돌리는 법** 네 가지를 넣는다. 내부 실행 ID·자격·로그 원문을 빼고 공개 검사를 거친다. PR은 해결 제안이며 배포·복구 완료가 아니다. 병합은 관리자만 한다.

### 5.3 병합 뒤 한 번의 확인

- PR을 올릴 때 조회식·대상·기대 결과·병합 뒤 대기 시간을 정한다. [추론] 감독이 중계 허용 범위와 상한을 검사해 고정하며, 시간을 정하지 않은 채 확인을 약속하지 않는다.
- 현관이 실제 병합을 확인하면 감독이 예약한다. 정해진 시간에 **모델을 깨우지 않고 코드가 관측 중계로 한 번** 조회하고 같은 스레드에 결과를 한 번 알린다. 예약과 발송 중복 키는 재시작 뒤에도 남는다.
- [추론] 기대 결과 충족 / 미충족 / 확인 불가를 구분한다. 관측 실패를 성공이나 자동 재진단으로 바꾸지 않는다. 이 확인은 반복 감시가 아니며, 이후 재발은 D-28의 규칙으로 처리한다.
- Argo 반영 대기나 관리자 적용이 남았으면 그대로 알린다. [확인] 이전 source로 재시도 중이면 되돌림 PR만으로 바로 복구되지 않을 수 있다(`docs/runbooks-public/apps.md:13`).

## 6. 관리자만 할 수 있는 일로 끝나는 경우

공개 런북의 절차는 [확인], 올리브가 멈추는 지점은 D-05·D-25에서 따른 [추론]이다. 필요한 이유·전제·위험·런북 위치를 알린다. 런북의 명령이 올리브의 권한을 늘리지는 않는다.

| 일 | 올리브가 알리고 끝낼 것 | 근거 파일:줄 |
|---|---|---|
| 공유기 DNS 전환 | AdGuard 중단 5분 초과 또는 NUC의 빠른 복구가 어려우면 임시 공용 DNS 전환. 복구 뒤 되돌림, 임시 전환 중 사용자 규칙 차이 | `docs/runbooks-public/nuc-dns-outage.md:13` |
| 자격 발급·회전·동기화·재시작 | Infisical → Secret → 실제 자격 → 앱 사용 순서. ExternalSecret 상태까지만 읽고 Secret 값·해시 비교도 하지 않음 | `docs/runbooks-public/rotate.md:10`, `:134`, `:184` |
| 진행 중 Argo 작업 종료 | 옛 source 재시도인지와 반영 상태를 안내. 시도 중 작업을 끊지 않도록 런북 판정은 관리자가 수행 | `docs/runbooks-public/apps.md:53` |
| 백업 생성·DB/Valkey 복원 | 복구 시점·손실 허용·임시 Cluster/Job·복원·정리는 관리자 판단. 백업이 오래됐다는 이유만으로 복원을 권하지 않음 | `docs/runbooks-public/restore.md:11`, `:462` |
| 호스트 설정·디스크·커널 | sudo 적용·재부팅·fsck·재마운트·데이터 정리는 관리자 조치. 검증된 절차 없이 삭제 명령을 만들지 않음 | `docs/runbooks-public/bootstrap.md:100`, `docs/runbooks-public/nuc-kernel-pin.md:53`, `docs/runbooks-public/restore.md:2127` |
| Terraform·외부 서비스 설정 | 선언 오류는 PR 후보. apply·Cloudflare/Tailscale 콘솔·DNS/ACL 변경은 관리자 작업 | `docs/runbooks-public/github.md:66`, `platform/observability/stack/vmalert/rules/adguard.yaml:76` |

[확인] 터널·Tailscale OAuth 등 회전 절차 일부는 아직 비어 있다(`docs/runbooks-public/rotate.md:304`). 인증서 경보 설명의 직접 로그 조회 안내는 올리브 권한 밖이고, Certificate 상태는 D-35로 읽을 수 있게 된다(`platform/observability/stack/vmalert/rules/platform.yaml:124`, `:170`). 없는 검증 절차를 지어내지 않고 관리자 확인 대상을 적는다.

자기 코드 문제는 원인·근거·고칠 위치만 알린다. 관리자의 개발 세션이 고친다. `homelab`의 올리브 배포 선언은 보호 경로이므로 등급 조건과 확인 카드를 거쳐 PR을 올릴 수 있다(D-25). PR과 관리자 조치가 함께 필요하면 둘 다 알린다.

## 7. 기본값(관리자 미확정) 여덟

아래는 [추론] 초깃값이다. J5는 D-34로 정해져 이 목록에 없다. 다른 여덟은 관리자 결정으로 승격하지 않는다.

| 항목 | 기본값 | 이유와 고르지 않은 안 |
|---|---|---|
| J1 송신자 확인 | 전용 경로 + 암호화 연결(TLS) + Alertmanager 전용 인증값. 모델·작업자에게 인증값을 주지 않음 | 기존 webhook을 쓰면서 송신자 위조를 줄임. 상호 TLS는 인증서 운영 부담, 네트워크 경로만 믿는 안은 발신자 확인 부족 |
| J2 실행 문자열 | 실행 중 리소스의 command·args는 통째로 가리고 고정 Git에서 확인. 중첩 inline 설정도 같은 처리 | 인코딩·셸 문자열 누출을 줄임. 자격 모양만 가리는 안은 live/Git 차이를 더 잘 보지만 놓칠 표면이 큼 |
| J3 조회 상한 | 로그 1시간·100줄·64KiB, 지표 일반 6시간·긴 판단 48시간. 세부는 §3.3 | 짧은 로그로 맥락·검색 부하를 줄이고 긴 백업·DNS 판단은 지표로 함. 로그 6시간·500줄·256KiB 안은 유출 표면과 부하가 큼 |
| J4 실행 예산 | 15분·20만 토큰·60조회, 자동 연장 없음. 2주 뒤 원인 확인률·상한 종료율·NUC 부하로 조정 | 조사 여유와 폭주 상한을 함께 둠. 10분·10만·40조회는 빠듯하고, 20분·30만·80조회는 비용·부하가 큼 |
| J6 하루 경계 | Asia/Seoul 자정. 횟수는 영속 기록 | 관리자가 이해하기 쉬움. 최근 24시간 이동 창은 자정 몰림에 유리하지만 계산이 덜 직관적. 자정 전후 각각 상한만큼 실행될 수 있음 |
| J7 묶음 계산 | 함께 실제 조사한 경보 이름마다 1회, 전체는 실행 1회. 같은 이름의 반복·여러 인스턴스는 중복 계산하지 않음 | 대표 경보만 세면 합류로 경보별 상한을 우회함. 클러스터·경보 이름으로 앞 결과를 찾고 여러 대상의 구분이 부족하면 관리자 수동 진단으로 보완 |
| J8 메모 만료 | 30일 뒤에는 만료 안내와 현재 승인된 런북. 영구 메모·자동 재진단 없음 | 정확한 옛 조치를 재현할 수 없음을 숨기지 않음. 만료 전 재사용 조치를 지식 PR로 만드는 안은 관리자 병합이 있어야 쓸 수 있어 초기 기본으로 고르지 않음 |
| J9 병합 없이 닫힌 PR | 재발 시 닫힌 사실을 한 번 알리고 관리자가 부탁할 때만 재진단 | 거절한 수정을 반복 제안하지 않음. 열린 PR이 없으면 자동 재진단하는 안은 고르지 않음. PR 상태 조회 실패나 PR·관리자 조치 없는 원인 찾음도 자동으로 원인 미상으로 바꾸지 않음 |

## 8. 확인하지 못한 것과 실제로 돌려 봐야 아는 것

- [미확인, O11] 가림 뒤에도 아홉 경보의 원인을 찾을 정보가 남는가. 합성 env·중첩 source·이벤트·로그·지표 라벨에 가짜 비밀과 지시문을 넣고 누출·지시 실행·과도한 가림을 함께 본다.
- [미확인, O11·O09] 출력 상한이 검색 부하도 막는가. 압축 해제 크기, 하위 질의 범위, 연결 종료 뒤 upstream 취소, 사용량 보고 지연, 호출 전 예산 예약, 계정 전환 뒤 예산 승계를 확인한다. 15분·20만 토큰은 실측 최적값이 아니다.
- [미확인, O11] 토큰 없는 kubectl의 discovery·JSON·페이지 커서와 실행 신원 연결. 다른 파드·재사용 IP·종료 직후 접근, Kubernetes API·로그·지표 직결·노드 로컬·DNS 우회, 중계 장애 시 직접 연결을 모두 막아야 한다.
- [미확인, O16] J1 인증 설정과 기존 Alertmanager의 호환성, 잘린 경보·중복 전송 처리. Telegram 전달을 유지한 채 확인한다.
- [미확인] 운영 클러스터는 이 문서 작성에서 조회하지 않았다. 추가 RBAC 바인딩·실제 CRD 버전·경보 상태·로그/지표 누락·Secret 참조 성공 여부·main과 운영의 일치는 확인하지 않았다. 금지 리소스로 보충하지 않는다.
- [확인 → 추론] 옛 봇 `src/catalog.ts:9`의 조회 네 개와 `src/read-transports.ts:56`의 마지막 값 중심 지표 처리는 넓은 진단을 대신하지 못한다. HTTP 제한·취소·리다이렉트 거부는 재사용 후보지만 가림·추세·영수증은 새 계약에 맞춘다. 근거는 `ukyi-app/homelab-bot`의 origin/main에서 읽었다.
- [추론, O11·O13·O16·O21] 한 갈래 근거, 빈 배제 칸, 모델의 거짓 확신, 다른 계열의 반박, 가설 PR 요청, 병합 뒤 확인 한 번, 관리자 요청의 등급 검사 제외를 AC-27로 확인한다. 경보 해소만을 성공으로 세지 않는다.
- [추론, O16·O21] 관리자 승인 뒤 자연 회복·수집 중단·백업 실패·인증서 실패·다른 critical 합류·열린 PR 재발·메모 만료·중계 장애를 한 번에 하나씩 재현한다. 이번 작성에서는 시험·운영 변경을 하지 않았다.
- 권한 밖 리소스나 호스트·외부 서비스가 원인이면 관리자 조치로 끝나는 한계가 남는다. NUC 전체 장애로 관측과 올리브가 함께 멈추는 경우는 `spec.md` §11.3대로 Telegram·Healthchecks가 맡는다.
