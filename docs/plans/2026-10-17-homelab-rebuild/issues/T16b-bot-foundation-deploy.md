# T16b 봇 FOUNDATION 실연동·첫 배포

- 단계: P4 봇 V1
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- 설계: [../platform/design.md](../platform/design.md) E.1 E9, C.8 "봇 자리 Application"
- Blocked by: T13, T16a
- 선행 결정: D-05 (확정(사용자 2026-10-18, T05): 공유 PostgreSQL 인스턴스 + 앱별 DB·역할), D-09 (확정(사용자 2026-10-18, T05): 옛 계열 최소 관측 구성), D-10 (확정(사용자 2026-10-18, T05): homelab 알림용 Telegram 새 봇 + healthchecks.io), D-13 (확정(사용자 2026-10-18, T14): 봇 저장소 `ukyi-app/homelab-bot`, 앱 이름 `homelab-bot`, 운영 산출물은 봇 저장소 밖), D-14 (확정(사용자 2026-10-18, T15): 봇 전용 ChatGPT 구독 계정 + 작업자 전용 CODEX_HOME. 인증 갱신본 되쓰기를 위한 작업자 전용 영속 쓰기 공간, 설계 C.8 변경), D-15 (확정(사용자 2026-10-18, T15): NUC 클러스터 안, 게시 서버 ns `app-homelab-bot`, 작업자는 `sandbox` ns 상주 파드(동시성 1), 라벨 `homelab-bot`, 앱·작업자 포트 8080, 경보 수신 포트 8081, 작업자 코드 읽기는 `codeload.github.com` 압축본만, U13 실패 때 호스트 전용 UID + nft), D-16 (확정(사용자 2026-10-18, T15): 기본안. 리뷰 App 생성·설치는 T17), D-17 (확정(사용자 2026-10-18, T15): 봇 전용 개인 서버와 아래 설정), D-24 (확정(사용자 2026-10-18, T15): 봇 전용 쓰기 GitHub App. App 이름·설치 저장소는 T19에서 정한다), V1 범위 조정 안 3 (확정(사용자 2026-10-18, T15): T16을 T16a와 이 티켓으로 나눔, STAGE별 제한 시범 운영)
- 연결 AC: AC-B3 (실연동과 첫 배포 증거. AC-B3 완료 판정은 이 티켓)
- 수행: 개발 에이전트 (`STAGE=FOUNDATION`) + 사람 (Discord 서버·봇 계정·Intents(D-17), 봇 전용 ChatGPT 구독 계정 준비와 작업자 `auth.json` 첫 시드(D-14. 시점은 T16b 전(모델을 처음 쓰는 단계 전). 이 티켓의 대화 레인이 모델을 처음 쓴다, 설계 E9), Infisical 봇 시크릿 등록, 봇 자리 `target` 변경 PR 검토·병합, 첫 배포 승인, 시범 운영 승인)

## 목표

`01` §4: Discord 대화, 영속 작업 저장소, 읽기 전용 홈랩 조회 (R01~R07)를 실제 Discord와 플랫폼에 연결한다. 봇을 플랫폼에 처음 배포한다. 로컬·mock 구현은 [T16a](T16a-bot-foundation-local.md)다.

## 할 일

1. 시작 전에 T15에서 `blocked`로 남긴 플랫폼 실측 항목을 다시 확인한다. 목록은 봇 저장소 `docs/ai-bot/DISCOVERY.md` §9(전체 blocked 목록)와 `VERIFICATION.md` 끝 점검표(확인 명령 14개)다. 둘을 합치면 읽기 계정 셋, Grafana 질의 범위(U12), Argo CD live ConfigMap, sandbox init 방화벽(U13)·DNS 없는 도구(U29)·작업자 ↔ 봇 Service 연결, webhook 경로(T08a), Alertmanager 봇 route·Telegram 형제 route·Watchdog, ruleset A~D, 새 Renovate·봇 App PR의 `author_association`, 봇 파드의 Discord IPv4 443 연결, 작업자 파드의 `codex sandbox -- true`와 `HTTPS_PROXY` 경유 모델 쪽 도메인 도달, `codeload.github.com` 허용과 다른 GitHub 호스트 거부, 영속 쓰기 공간 유지다. 결과가 T16a의 계약을 바꾸면 계약과 시험을 먼저 고친다.
2. Discord를 준비한다(D-17). 사람이 하고 [../approvals.md](../approvals.md)에 기록한다 (AC-X2).
   - 봇 전용 개인 서버를 만들고 채널 둘(대화, 알림·리뷰·브리핑)을 둔다.
   - Developer Portal에서 앱·봇을 만든다. Public Bot 끔, 서버 설치만, Interactions Endpoint URL 비움(Gateway로 받음), `MESSAGE_CONTENT` 특권 intent 켬.
   - 관리자·MANAGE_THREADS·MENTION_EVERYONE 권한은 주지 않는다. 권한은 서버 역할이 아니라 허용 채널 overwrite로 준다.
   - 봇 토큰과 서버·채널·허용 사용자(owner 1명) ID는 Infisical `/apps/homelab-bot/`에만 둔다. 저장소와 공개 문서에는 쓰지 않는다.
3. T16a의 계약을 실제 Discord와 플랫폼 읽기 계정에 연결하고 실연동 결과를 낸다. Grafana 질의 템플릿은 실제 Grafana에서 허용 밖 질의가 거부되는지 본다(READ-02). Grafana·Argo CD `bot-reader` 토큰은 설계에 보관 위치가 없어 봇 저장소 `ARCHITECTURE.md` §5가 `/apps/homelab-bot/`의 키 이름(`GRAFANA_READER_TOKEN`, `ARGOCD_READER_TOKEN`)을 제안했다. T08b가 넘긴 것(2026-10-23):
   - Grafana 서비스 계정 `bot-reader`(Viewer)와 Argo CD 로컬 계정 `bot-reader`(apiKey)는 있고 토큰은 없다. 토큰은 이 단계에서 만들어 위 키에 바로 넣는다(화면·파일에 남기지 않는다). Grafana 데이터소스는 읽기 전용 vmauth 뒤에 있어 Viewer 토큰으로 질의는 되고 `delete_series`·import는 막힌다(설계 U12 결과).
   - 봇의 로그 읽기 경로는 정해지지 않았다. 설계 C.8 (c)는 Grafana Viewer로 로그를 읽게 하지만 C.3.7은 플러그인 없음이라 VictoriaLogs 데이터소스가 없다. 플러그인을 고정해 허용할지, 읽기 프록시를 둘지 이 단계에서 정한다(lead 결정 2026-10-22, T08b).
   - 작업자 egress 허용 목록에 npm이 없다(받기와 게시가 같은 호스트라 뺐다, 설계 C.8 쓰기 유출). 봇 작업이 npm 패키지를 받아야 하면 GET 전용 미러를 정한다.
4. 첫 배포를 아래 순서로 한다(설계 E9).
   - **선행(보안): capability nonce 정규화.** T16a PR #5에서 이월한 지적이다(할 일 6). 봇 저장소 `src/worker.ts`에서 서명에 `=`·`!` 같은 문자를 덧붙인 비정규 base64url이 같은 바이트로 검증되지만 nonce는 새 값으로 소비돼, 30초 안에 같은 작업을 다시 실행할 수 있다. canonical base64url만 받거나 검증된 payload와 서명 바이트로 nonce 키를 만든다. 이 수정이 봇 저장소 main에 병합된 뒤에 아래 1을 시작한다 [제안].
   1. 에이전트: 등록 전에 봇 저장소 워크플로를 템플릿의 `build.yaml`(`app-build@<태그>` 호출)로 맞추는 PR을 먼저 병합한다(설계 E9 선행 조건, 병합은 사람). 플랫폼 CLI(`homelab app add homelab-bot`)로 봇을 등록하고, DB를 추가하고, 시크릿 참조를 선언한다. 값은 넣지 않는다. 봇 values에 `serviceAccountName: bot-reader`를 둔다(설계 C.4.5).
   2. 사람: Infisical에 봇 시크릿을 등록한다. 게시 서버 값은 `/apps/homelab-bot/`, 작업자 값은 `/apps/homelab-bot/worker`로 나눈다(설계 E9). 봇이 실행 중 읽는 runtime-policies와 허용 목록의 실제 값도 `/apps/homelab-bot/`에 둔다(D-13).
      - 작업자 값은 봇 전용 ChatGPT 구독 계정(D-14)의 시드 `auth.json`이다. 계정 준비와 시드를 만들어 `/apps/homelab-bot/worker`에 등록하는 일은 사람이 한다(설계 E9 선행 조건의 사람 작업, spec §11 모델 행). 이 단계에서는 등록돼 있는지 확인한다. 개인 `~/.codex*`는 쓰거나 복사하지 않는다. [../approvals.md](../approvals.md)에 기록한다.
      - 시점: T16b 전(모델을 처음 쓰는 단계 전)이다. 이 티켓의 대화 레인이 모델을 쓰므로 이 티켓을 시작하기 전에 끝나 있어야 한다(설계 E9와 같다. 시점은 에이전트가 맞춘 정리이고 사용자 결정이 아니다). T17·T18은 이 준비가 끝났다고 전제한다.
   3. 봇 자리 Application `platform/bot-slot`의 `target` 변경 PR을 봇 등록 PR보다 먼저 병합한다(아래 "봇 자리 `target` 변경"). 병합 뒤 검증의 콜드스타트 (2) 앞부분으로 `bot-slot`이 봇 ns를 기다리는 상태인지 본다.
   4. 사람이 승인한 뒤 봇 등록 PR을 병합해 첫 배포를 한다. ArgoCDAppDegraded 경보(30분)가 울리기 전에 병합한다.
   5. T08b의 시험 수신기를 봇으로 바꾸고, 격리 공간에 작업자를 둔다(설계 E9). Alertmanager 봇 route를 켤 때 Telegram 형제 route를 함께 켠다. `continue: true`는 부모 receiver로 되돌려 보내지 않아, 형제 route가 없으면 경보가 봇으로만 가고 비AI 경로(AC-P11)가 끊긴다(설계 C.3.7).
      - App 설치 시점: 이 티켓은 App을 만들거나 설치하지 않는다(설계 E9). 리뷰 App(D-16) 생성·설치는 T17이 시험 저장소부터 한다. 변경 PR App(D-24)은 이름·설치 저장소를 T19에서 정하므로 T19 할 일에서 설치한다. 두 App은 HANDOFF에 해소 티켓(T17, T19)과 함께 적는다.
      - 작업자 배치(D-14, D-15): `sandbox` ns의 상주 파드 하나(동시성 1, replicas 1. `strategy: Recreate`는 T08b의 [제안]), 작업자 포트 8080. 작업자 egress의 코드 읽기는 T08b의 `codeload.github.com`만 그대로이고 `github.com`·`api.github.com`·`gist.github.com`은 뺀다. 작업자에는 GitHub 자격이 없다. 개인 `~/.codex*`는 쓰거나 복사하지 않는다.
      - 영속 공간과 첫 시드(D-14): T08b가 `platform/sandbox`에 만든 작업자 전용 영속 쓰기 공간(`CODEX_HOME`용 PVC 하나)을 쓴다. 작업자는 그 공간에 `auth.json`이 없을 때만 Infisical `/apps/homelab-bot/worker`의 시드를 복사한다. 그래서 처음 배치 때 미리 등록한 시드(할 일 4.2)가 영속 공간에 들어가고, 파드를 다시 만들 때는 갱신본을 시드로 덮지 않는다(설계 C.8 격리 행).
      - 모델·인증 호스트(D-14): 구독 인증 Codex가 쓰는 모델·인증 호스트를 실측해 egress 허용 목록에 넣는다(설계 E9. T15에서는 [미확인]).
      - 파드 방화벽(U13)이 T08b에서 실패로 끝났으면 작업자를 호스트 전용 UID + nft로 둔다(D-15 대안).
      - 작업자 이미지의 빌드·배포 경로는 설계에 없다 [미확인: 봇 저장소 `ARCHITECTURE.md` §10]. 작업자를 두기 전에 정한다.
   6. 플랫폼 프롬프트 §9 시나리오 1 형태로 실행을 확인한다(배포 PR, 병합, Argo CD 배포, 실행 확인).
   - 못 하면 `blocked`와 사유를 HANDOFF에 적는다.
   - 승인은 [../approvals.md](../approvals.md)에 남긴다 (AC-X2).
5. 봇 중단 경보(OPS-02)를 실제로 확인한다. Gateway만 끊겼을 때 봇이 Ready를 유지해 webhook(8080)·경보 수신(8081)이 계속 되는지와 Gateway 연결 지표 경보가 오는지를 함께 본다. T16a가 만든 readiness 연동과 하트비트를 쓰려면 사람이 봇 전용 healthchecks.io 체크를 만들고 ping URL을 `/apps/homelab-bot/`에 등록한다(봇 저장소 `ARCHITECTURE.md` §8 제안). Bun 위 Discord Gateway의 네트워크 차단·복구 시험(discord.js 이슈 #10840, not planned 종료)을 여기서 한다. 실패하면 Node 24 전환을 검토한다 [가정: `ARCHITECTURE.md` §3].
6. T16a PR #5(`ukyi-app/homelab-bot`, 병합 `7f649c9`)에서 이월한 Codex 리뷰 P2 6개를 봇 저장소 PR로 고친다. 마지막 재리뷰(head `1a639db`)에 P1이 없으면 병합하고 남은 P2는 이 티켓으로 옮긴다는 멈춤 규칙에 따른 것이다(사용자 2026-10-20). 스레드마다 처리 방향을 답글로 남겼다.
   - **capability nonce 정규화(`src/worker.ts`, 보안 성격):** 첫 배포 전에 고치도록 할 일 4의 선행 단계로 옮겼다.
   - **JSON 페이지 밖 marker(`src/discord.ts`):** 긴 `/list` 게시물의 각 페이지 뒤에 붙는 `[ref:...]`가 JSON 파싱을 깬다. marker를 JSON 필드나 별도 메타데이터로 옮긴다.
   - **모델 응답 생략 표시(`src/runtime.ts`):** 섹션 350자 `slice()`가 항목을 조용히 버린다. 완결 항목 단위로 줄이고 생략 건수를 표시한다(`summaryItems()`와 같은 방식).
   - **marker 검색 실패 backoff(`src/discord.ts`):** `external_id`가 없는 unknown 행이 매 `reconcile()`마다 최대 10페이지 history를 다시 조회한다. 검색 실패 때도 다음 대조 시각을 저장하고 조회 조건에 쓴다.
   - **`/retry` 큐 상한(`src/store.ts`):** 재시도 전이가 queued 개수를 보지 않아 `DEFAULTS.maxQueue`(100)를 넘을 수 있다. scheduler 행 잠금 아래에서 개수를 확인한 뒤 전이한다.
   - **read 타임아웃 중단(`src/read.ts`):** 5초 `Promise.race()`가 실제 요청을 멈추지 않아 반복 timeout에서 요청이 직렬성 밖에 쌓인다. `ReadTransport`에 `AbortSignal`을 넘겨 abort한다.

### 봇 자리 `target` 변경 (설계 E9, C.8)

- T08b가 만든 `platform/bot-slot`의 `values.yaml`에서 `target`을 봇 ns `app-homelab-bot`, 라벨 `homelab-bot`, D-15가 정한 작업자 포트 8080·경보 수신 포트 8081로 바꾸고, `probe: false`로 시험 ns `bot-slot-probe`와 손으로 옮긴 정책을 지운다. 이 값 하나로 봇 쪽 NetworkPolicy의 대상, sandbox ingress의 출처, SA `bot-reader`의 ns가 함께 바뀐다. 작업자 포트는 `platform/sandbox`의 작업자 컨테이너 포트와 같아야 한다.
- `image.yaml` 밖의 platform 변경이라 자동 병합 대상이 아니고 사람이 검토 후 병합한다.
- 봇 등록 PR보다 먼저 병합하는 이유: 빈 클러스터에서 생기는 "봇 ns보다 봇 자리가 먼저 sync되는" 콜드스타트 순서를 운영에서 재현해 확인하려는 것이다. `bot-slot`은 대상 ns를 만들지 않고(`CreateNamespace` 없음) wave 1, `retry.limit: -1`, `retry.refresh: true`라 봇 ns가 생길 때까지 재시도하다 수렴해야 한다.

## 시범 운영 (완료 뒤)

- 이 티켓이 끝나면 허용 채널에서 읽기 조회만 실사용한다(V1 범위 조정 안 3, 확정(사용자 2026-10-18, T15)). V1 출시 판정 기준은 그대로다.
- 시작 전에 사람이 승인하고 [../approvals.md](../approvals.md)에 기록한다.

## 완료 조건

- `04` §4 시험 AUTH-01·02, EVENT-01~04, CHAT-01·02, READ-01·02, SEC-01, OPS-01·02의 결과가 기록돼 있다 (spec §7 AC-B3). T16a의 `mock`·`local_integration` 결과에 실연동 결과를 더하고, 둘을 구분한다.
- spec §7 "단계 AC 공통 완료 규칙"을 따른다. 배정된 시험에 `fail`이 없다. `blocked`·`not_run`은 사유와 해소 티켓을 함께 적는다. 이 단계의 보안 경계 시험(AUTH-01, READ-02, SEC-01)은 이 경로에서 최소 `mock` 또는 `local_integration`으로 `pass`다.
- 봇이 플랫폼에 처음 배포됐다는 증거(배포 PR, Argo CD 상태, 실행 확인)가 있다.
- 봇 자리 Application의 콜드스타트 순서 확인(아래 검증 (1)·(2))을 통과했다.
- 봇에 대해 시나리오 1을 통과했다(두 번째 커밋의 자동 병합 포함). 설계 C.8 표 명령을 실제 봇(실제 차트 렌더)으로 다시 통과했다(설계 E9). 작업자 egress가 `codeload.github.com`과 실측한 모델·인증 호스트를 허용하고 `github.com`·`api.github.com`·`gist.github.com`을 거부하며, 작업자 파드를 다시 만든 뒤에도 영속 공간의 `auth.json`이 시드로 덮이지 않는다.
- 봇 전용 구독 계정 준비와 `auth.json` 첫 시드가 [../approvals.md](../approvals.md)에 기록돼 있다(D-14).
- 봇 저장소 `ukyi-app/homelab-bot`이 public이고 보안 설정(D-29)이 켜져 있으며, 운영 산출물(evidence, handoffs, runtime-policies 실제 값 등)이 저장소에 없다(D-13, 설계 C.8 봇 저장소).
- Alertmanager 봇 route를 켠 뒤(Telegram 형제 route 함께) 봇이 정상일 때와 replicas 0일 때 모두 시험 경보가 Telegram에 도착했다.
- HANDOFF가 있다.

## 검증

`04` §4 시험. `mock`과 실제 연동 결과를 구분한다.

작업자 배치(D-14, D-15):

- 작업자 파드에서 프록시 경유 `codeload.github.com` → 연결, `github.com`·`api.github.com`·`gist.github.com` → 프록시 거부.
- 작업자 파드에서 프록시 경유 실측한 모델·인증 호스트 → 연결. 넣은 호스트 목록을 HANDOFF에 적는다.
- 작업자 파드를 다시 만든 뒤에도 영속 쓰기 공간의 파일이 남고, `auth.json`이 Infisical 시드로 덮이지 않는다(설계 E9). 값은 출력하지 않고, 비교할 때는 `sha256sum` 결과만 본다.

봇 자리 Application의 콜드스타트 순서(설계 E9 검증):

- (1) 렌더: `helm template root platform/root -f platform/root/values-prod.yaml | yq -N 'select(.kind == "Application") | .metadata.name + " " + (.metadata.annotations."argocd.argoproj.io/sync-wave" // "0")' | sort -k2 -n | tail -2` → 마지막 줄이 `bot-slot 1`이고 그 앞 줄의 wave는 0 이하(뒤 wave 없음). 같은 렌더에서 `bot-slot`의 `spec.syncPolicy`에 `CreateNamespace=true`가 없고 `retry.limit`이 `-1`, `retry.refresh`가 `true`다.
- (2) 재현: `target` 변경 PR을 봇 등록 PR보다 먼저 병합한다 → `kubectl -n argocd get application bot-slot -o jsonpath='{.status.operationState.phase} {.status.operationState.message}'`가 phase `Running`이고 메시지에 `namespaces "app-homelab-bot" not found`와 `Retrying attempt`가 있다(무제한 재시도라 Failed가 되지 않는다). root·`bot-slot` 밖의 Application은 Synced·Healthy 그대로다 → 봇 등록 PR 병합(ArgoCDAppDegraded 30분 경보 전에) → backoff 상한 5분 안팎에 `bot-slot` Synced·Healthy, SA `bot-reader`가 생긴 뒤 봇 파드 Ready.
- 재현은 root의 wave 진행을 다시 거치지 않으므로 (1)과 함께 본다.

## 되돌리는 방법

- `homelab app remove homelab-bot`(데이터 보존)과 봇 자리 `target`을 T08b의 시험 값(ns `bot-slot-probe`, 시험 라벨·포트)으로 되돌리고 `probe: true`를 함께 켜는 PR(설계 E9, C.8). 시험 ns는 `probe: true`일 때만 선언된다. `target`을 봇 값으로 남기면 다음 콜드스타트에서 `bot-slot`이 끝없이 기다린다.
- T17·T19 뒤라면 App 설치 해제(설계 E9). 이 티켓은 App을 설치하지 않는다.
- 되돌리기 실행도 [../approvals.md](../approvals.md)에 기록한다.
