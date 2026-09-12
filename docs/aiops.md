# AIOps 파일럿 — 설치와 수용

`bash infra/k3s-bootstrap/aiops-install.sh --prepare`가 `.scratch/aiops-install/plan/`에 검토할 설정과 유닛을 만든다.
현재 구현은 로컬 재생과 설치 준비 단계다. 실제 NUC cgroup·전용 구독 로그인·알림 전달·fork PR의 수용 증거는 별도로 기록한다.
NUC가 꺼진 장애, 자동 복구·머지, 다른 앱 레포 수정, Polyrelay 연결은 이 파일럿의 실행 범위 밖이다.

## 1. 사건을 재생한다

```bash
bun tools/aiops.ts --help
bun tools/aiops.ts ingest --state-dir .scratch/aiops-demo --input incident.json
bun tools/aiops.ts list --state-dir .scratch/aiops-demo
bun tools/aiops.ts replay --state-dir .scratch/aiops-demo --incident <사건-ID>
```

입력은 `source,eventId,target,observedAt,revision,severity,reason,status`의 JSON이다. `source`는
`alertmanager,argocd,cnpg,gha,healthchecks`, 상태는 `firing,resolved,unobservable`이다.
관측 실패는 기존 firing을 해소하지 않는다. 사건·실행·게시 상태는 독립적이며, 모의 보고서에는 `simulated:true`가 붙는다.
같은 상태 디렉토리에서 모의 실행과 구독 실행을 섞을 수 없다. 날짜별 입장 원장은 KST, 동시 1건·하루 20건이다.
중단·재시도도 입장 횟수에 포함하고, 정리 여부가 불명이면 새 실행을 막는다.
확인된 엔진 시작 실패는 같은 10분 상한 안에서 한 번만 재입장한다. 인증 만료·구독 용량 제한은
`waiting-authentication`·`waiting-capacity`로 영속 대기한다. 로그인 또는 구독 한도 회복을 확인한 뒤
`resume --incident <ID>`로 다시 대기열에 넣는다. 재개 명령은 예산을 환급하지 않는다.

`collect`는 선별 자료 파일, `collect-live`는 고정 kubectl 조회와 내부 메트릭 API를 사용한다.
대상 워크로드가 매칭되지 않거나 메트릭이 비어 있으면 누락을 기록한다. 모델 증거는 256 KiB,
컨테이너별 로그는 200줄이다. Secret·Pod env는 선별하지 않고 로그의 알려진 자격 표기를 제거한다.
지원 로그는 text·JSONL·kubectl timestamp 접두다. 깨진 JSON·바이너리는 생략하며 JSON의 따옴표로 감싼 자격값도 제거한다.
`diagnose --mode replay`는 외부 엔진 대역을 호출하며 빈 인증 디렉토리를 쓴다. 실제 구독 실행은 `worker`의 전용 역할 경로만 지원한다.

`validate`는 기준 Git의 원장 파서·정책과 후보의 행을 결합한다. 상한은 **기준 revision의 활성 `ledger:meta`**에서만 읽는다.
기준 상한이 없거나 기형이면 검증 불가다. 후보 상한 제안은 별도 판정이다. JSON/YAML/bash 문법도 검사하지만
Helm 템플릿·암호화 자료·live/Terraform·나머지 저장소 게이트는 미검증으로 남긴다.
후보 CI 결과로 고정 검증 결과를 대체하지 않는다. 변경된 정책·ADR도 보고서에 표시한다.

## 2. NUC에 설치한다

설치기의 `--install <config.json> <bun 절대경로> <codex 절대경로> <conftest 절대경로>`는 sudo가 필요하다.
커밋한 실행 코드를 `/opt/homelab-aiops/<revision>`에 고정하고 바이너리 해시를 설정에 기록한다.
설정의 `revision`은 조사·검증할 homelab 기준 commit이다. 저장소에 해당 commit이 있어야 한다.
기준 main이 전진하면 저장소 사본과 설정을 갱신하고 수용 증거를 다시 확인한다. 오래된 기준으로 새 PR은 만들지 않는다.
기본 kubectl 경로는 k3s의 `/usr/local/bin/kubectl`이며 설치 전 실행 가능 여부를 검사한다.
SQLite DB/WAL은 `0660`, 운영 state 디렉토리는 root:`aiops-state`의 `2770`으로 유지한다.

| 역할 | 접근 자료 | 허용 작업 |
|---|---|---|
| `aiops-collector` | 읽기 전용 kubeconfig·GitHub·healthchecks, 생산자 토큰, 사건 저장소 | 정해진 관측 조회·수신 |
| `aiops-engine` | 전용 구독 인증, 선별 증거·Git 사본 | 네트워크 없는 Codex 도구 sandbox 안에서 조사 |
| `aiops-validator` | 기준·후보 사본 | 무자격 검사 |
| `aiops-fork` / `aiops-pr` | 각 역할 전용 GitHub 토큰 | fork Git Data 쓰기 / upstream Draft PR 생성·조회 |
| `aiops-telegram` | 전용 Telegram 토큰·chat ID | 요약 발송 |

조정기는 root로 systemd 작업을 시작하고 사건 상태만 조정한다. 모델을 root 프로세스 안에서 실행하지 않는다.
역할 작업에는 표준 입출력 외 FD와 상속 인증 환경을 전달하지 않는다. engine 인증은 도구 workspace 밖에 놓으며
직접 파일·symlink·부모 `/proc`·환경·FD·소켓·네트워크 접근을 실제 Codex sandbox로 검증한다.
설치된 Codex는 `0.154.0`이며 모델 기본값은 `gpt-6-astra`다. API 키 fallback은 허용하지 않는다.
`forced_login_method="chatgpt"`와 파일 인증 저장소를 고정한다.

수집 120초/512MiB/1MiB, Codex 600초/2GiB/8MiB, 검증 300초/2GiB/8MiB, 게시 합계 60초/256MiB/1MiB다.
전체 시도는 1200초다. systemd `KillMode=control-group`, `TimeoutStopSec=10`, 메모리·CPU·PID 제한을 사용한다.
단계 unit 이름은 시작 전에 영속화하고 재시작 시 정리를 확인한다. 영속 저장은 전용 512 MiB 파일시스템,
각 단계 `/tmp`는 256 MiB tmpfs다. 사건/보고서는 최근 변경 후 30일, 증거/원문 실행 로그는 7일 보존한다.

## 3. 인증과 생산자를 연결한다

토큰 값을 채팅·명령 인자에 넣지 않는다. 설정 템플릿의 역할별 파일에 소유자 전용 권한으로 저장한다.
전용 fork는 원본 homelab의 fork여야 하고 Actions를 비활성화한다. fork 토큰은 그 fork의 Contents+Workflows 쓰기,
PR 토큰은 homelab의 Pull requests 쓰기와 Contents 읽기로 제한한다. engine/validator에는 두 토큰을 전달하지 않는다.
ChatGPT 로그인은 `aiops-engine` 계정의 `/var/lib/homelab-aiops/auth`에서 진행한다. 설치 이전 개인 인증을 복사하지 않는다.
healthchecks에는 **읽기 전용 API 키**를 사용한다. UUID·ping URL 대신 읽기 전용 `unique_key`로 체크와 flips를 조회한다.

```bash
bun tools/aiops.ts producer-plan --state-dir .scratch/aiops-install/state \
  --repo "$PWD" --output .scratch/aiops-install/producers --address <NUC-사설-IP>
```

생성된 Alertmanager 설정은 기존 Telegram/Watchdog 경로 앞에 병렬 수신자를 추가한다. 배포 패치의 토큰 Secret을 먼저 준비한다.
ArgoCD는 **bootstrap seed만 바꾸면 live에 적용되지 않는다**. 생성된 merge JSON을 live notifications ConfigMap에 병합하고
기존 subscriptions에 AIOps 구독을 추가한다. 같은 변경을 bootstrap seed에도 반영해 재구축 드리프트를 막는다.
토큰은 notifications Secret의 `aiops-token`이다. URL에는 토큰을 넣지 않는다.
정상과 실패는 별도 trigger 조건으로 두고 revision `oncePer`로 같은 SHA의 상태 전이를 억제하지 않는다.
조건 묶음과 선택 필드는 [ArgoCD trigger 계약](https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/triggers/)을 따른다.

CNPG 두 Job은 선택적 `aiops-endpoint` ConfigMap과 `aiops-observation-auth` Secret을 읽는다.
database Secret의 `authorization` 키에는 HTTP Authorization 헤더를 저장한다. restore-drill은 정리 완료까지 확인한 후 healthy를 보낸다.
Alertmanager의 observability Secret은 raw `token` 키를 사용한다. 서로 다른 생산자 토큰을 재사용하지 않는다.
기존 `.enc.yaml`은 직접 편집하지 않고 SOPS 복호화→편집→재암호화 또는 새 SealedSecret 절차를 쓴다.

21980/TCP는 고정 사설 인입이다. NUC 방화벽과 해당 namespace의 NetworkPolicy에서 필요한 Pod→NUC 경로만 연다.
생성물 `host-ingress.nft`는 실제 Pod CIDR·NUC 주소와 대조한 뒤 기존 방화벽에 추가한다.
`argocd-aiops-egress.yaml`은 이미 격리된 notifications의 NUC 접근만 허용한다. AM/CNPG의 기존 통신을 닫는 새 Egress 정책을 만들지 않는다.
수신기는 전 인터페이스 주소·공개 주소를 거부하며 bearer 인증 후 영속 저장을 완료해야 응답한다.
GHA는 Telegram 조건과 독립된 artifact를 기록한다. workflow/run/attempt/repository/revision을 검증하며
누락·skip·부분 실행은 정상으로 접지 않는다. DNS는 대상별 정상/경고/미관측을 구별한다.
최신 100건과 최근 30일의 고정 기간 페이지를 함께 조회하고 순회 cursor를 저장한다. 큰 검색 구간은 분할하며
관측 0건·과거 순회 미완료·artifact 누락은 수집 성공으로 기록하지 않는다. 오래된 run의 새 attempt도 다시 대조한다.
`github.observationSince`에는 실제 관측 artifact 배포 시각을 한 번 기록한다. 전환 이전에 마지막으로 갱신된 run만
제외하며, 그 뒤 재실행된 이전 run은 수집한다. 이력의 복구 불가 구간은 source 상태에 남긴다.
역할별 설정을 바꾼 뒤에는 비활성 상태에서 설치된 `aiops-install-config.ts write`로 역할 설정 사본도 다시 생성한다.

## 4. 수용 증거를 기록한다

```bash
sudo <bun-절대경로> tools/aiops.ts probe-host --state-dir /tmp/aiops-host-probe
bun tools/aiops.ts probe-isolation --state-dir .scratch/aiops-install/state --engine <설치된-codex>
bun tools/aiops.ts readiness --state-dir .scratch/aiops-install/state --config <config.json>
```

`probe-host`는 모의 자격만 사용하는 임시 systemd 작업으로 허용 대조군·다른 UID 자격 거부·timeout·setsid 자식·OOM·출력 한도를 확인한다.
실행할 수 없으면 sudo 인증을 완료한 owner가 이 명령을 실행한다. 로컬 프로세스 그룹 테스트 통과를 cgroup 증거로 기록하지 않는다.
실제 재부팅 후 복구, 단계별 역할 접근, 구독 로그인, 모든 생산자 도달, fork Actions 비활성화, 실제 Draft PR/Telegram 발송은 별도 수용이다.
발송 여부·권한은 실제 API 결과로 확인한다. 읽기 설정만 보고 쓰기 권한이 맞다고 판정하지 않는다.

`acceptance.json`은 root 소유·그룹/타인 쓰기 금지 파일이다. `isolation,roles,cgroup,producerDelivery,subscription,forkActionsDisabled,publication,diagnosticCases`
각 키에 `passed,revision,engineHash,checkedAt` 증거를 기록한다. 미수행 항목을 true로 채우지 않는다.
이 증거는 최대 30일간 유효하며 기준 revision 또는 engine 해시가 바뀌면 다시 수용한다.
`readiness` 결과의 pending 항목이 남아 있으면 worker는 모델을 호출하지 않는다.

실제 진단·게시의 수용 증거는 `commission`으로 만든다. `enabled:false`에서 사건을 명시하는 1회 실행이다.
바이너리·구독 인증 파일·저장소·격리·역할·cgroup·fork Actions 비활성화는 먼저 통과해야 한다.
생산자 도달·실제 구독 실행·게시·12개 진단 평가·관찰 기준은 이 시험 경로로 확인하고 기록한다.
시험도 같은 역할·자원 제한·동시 1건·하루 20회 원장을 사용하며 실제 Telegram/Draft PR을 만들 수 있다.

```bash
sudo /opt/homelab-aiops/current/bin/bun /opt/homelab-aiops/current/tools/aiops.ts commission \
  --state-dir /var/lib/homelab-aiops/state --config /etc/homelab-aiops/config.json \
  --incident <사건-ID> --input <선별-사례-증거.json>
```

`--input`을 생략하면 실제 관련 증거를 수집한다. 제공한 사례 자료도 collector의 필드 선택과 마스킹을 거친다.
사전 수용을 위해 전체 readiness 증거를 미리 true로 채우거나 worker를 활성화할 필요가 없다.

진단 자료는 `tools/fixtures/aiops/cases.json`의 12개 사례다. 정답 파일은 Git 사본 밖에 보관하며 입력과 hash를 분리한다.
이 작업의 로컬 정답은 `.scratch/aiops-codex/evaluation/answers.json`이다. 사례별 보고서를 `<id>.json`으로 저장한 뒤:

```bash
bun tools/aiops.ts evaluate --state-dir .scratch/aiops-eval/state \
  --cases tools/fixtures/aiops/cases.json --answers <Git-밖-정답.json> --reports <보고서-디렉토리>
```

키워드/근거 ID 대조는 수동 품질 검토 자료다. 모의 결과·보고서 부재로 진단 품질을 입증하지 않는다.

## 5. 관찰을 시작하거나 중지한다

관찰의 최소 사건 수·다섯 계열 범위·품질 기준·수동 대응 시간 비교를 설정의 `observation`에 먼저 채운다.
수용을 통과한 뒤에만 `observation-start --config`와 `enabled:true`, worker timer·ingress 활성화를 진행한다.
`observation-record --input`은 사건 ID와 `manualMinutes,reviewMinutes,falsePositive,deferred`를 기록한다.
`observation-summary`는 표본·기간·확인된 사용량/미확인 사용량을 구별한다. 14일 경과만으로 성공 판정을 내리지 않는다.

중지는 `sudo systemctl disable --now aiops-worker.timer aiops-ingress.service`로 새 입력/입장을 막고,
`sudo systemctl stop aiops-worker.service` 후 `recover`로 기록된 단계 cgroup 정리를 확인한다.
정리 불명 예약을 수동 삭제해 진행하지 않는다. 롤백 시 producer 설정을 이전 Git 설정으로 복구하고
ArgoCD live seed 병합 변경도 되돌린다. 저장소·인증 파일·512 MiB 이미지는 삭제하지 않는다.

공식 계약: [Codex permissions](https://learn.chatgpt.com/docs/permissions),
[Codex config reference](https://learn.chatgpt.com/docs/config-file/config-reference),
[healthchecks read-only API](https://healthchecks.io/docs/api/).
