# T16b 봇 FOUNDATION 실연동·첫 배포

- 단계: P4 봇 V1
- 상태: 완료 (2026-11-02. 2026-10-30 착수. 첫 배포(등록 PR #995, 2026-10-30), 콜드스타트 순서 재현, 시나리오 1(#1005·#1010), 실연동 시험 S16 실행. 배정 시험에 fail 없음: EVENT-03은 첫 실행 부분 fail → 봇 #20 → 재시험 pass, EVENT-01 not_run과 EVENT-02 부분은 사유·해소 티켓과 함께. 결과는 아래 "결과", 시험 표는 봇 저장소 `docs/ai-bot/VERIFICATION.md` "T16b 실연동 결과". 시범 P-1은 2026-11-02 18:31 사용자 승인으로 진행 중(범위: 허용 채널의 `/read`와 대화). 공개 webhook 이전 PR #1003은 열림, 사용자 결정 대기)
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
   - 로그는 Grafana의 VictoriaLogs 데이터소스(uid `victorialogs`, 플러그인 v0.33.1)로 `POST /api/ds/query`에 LogsQL을 보내 읽는다(T08b #849, 사용자 결정 2026-10-23). 이 데이터소스도 읽기 전용 vmauth 뒤라 `/insert/*`·삭제 경로는 막혀 있다. Grafana의 데이터소스 응답 상한은 4MiB라 한 질의는 약 6000줄까지다. 실시간 tail(`/select/logsql/tail`)은 열지 않았다. 봇 질의 템플릿의 필드 이름(네임스페이스 등)은 실제 로그로 맞춘다.
   - 작업자 egress 허용 목록에 npm이 없다(받기와 게시가 같은 호스트라 뺐다, 설계 C.8 쓰기 유출). 봇 작업이 npm 패키지를 받아야 하면 GET 전용 미러를 정한다.
4. 첫 배포를 아래 순서로 한다(설계 E9).
   - **선행(보안): capability nonce 정규화.** T16a PR #5에서 이월한 지적이다(할 일 6). 봇 저장소 `src/worker.ts`에서 서명에 `=`·`!` 같은 문자를 덧붙인 비정규 base64url이 같은 바이트로 검증되지만 nonce는 새 값으로 소비돼, 30초 안에 같은 작업을 다시 실행할 수 있다. canonical base64url만 받거나 검증된 payload와 서명 바이트로 nonce 키를 만든다. 이 수정이 봇 저장소 main에 병합된 뒤에 아래 1을 시작한다 [제안]. 결과: 봇 PR #10(main `a1632bc`, 2026-10-30 11:11)이 canonical base64url만 받고 nonce 키를 서명된 payload의 SHA-256으로 만든다.
   1. 에이전트: 등록 전에 봇 저장소 워크플로를 템플릿의 `build.yaml`(`app-build@<태그>` 호출)로 맞추는 PR을 먼저 병합한다(설계 E9 선행 조건, 병합은 사람). 플랫폼 CLI(`homelab app add homelab-bot`)로 봇을 등록하고, DB를 추가하고, 시크릿 참조를 선언한다. 값은 넣지 않는다. 봇 values에 `serviceAccountName: bot-reader`를 둔다(설계 C.4.5).
   2. 사람: Infisical에 봇 시크릿을 등록한다. 게시 서버 값은 `/apps/homelab-bot/`, 작업자 값은 `/apps/homelab-bot/worker`로 나눈다(설계 E9). 봇이 실행 중 읽는 runtime-policies와 허용 목록의 실제 값도 `/apps/homelab-bot/`에 둔다(D-13).
      - 작업자 값은 봇 전용 ChatGPT 구독 계정(D-14)의 시드 `auth.json`이다. 계정 준비와 시드를 만들어 `/apps/homelab-bot/worker`에 등록하는 일은 사람이 한다(설계 E9 선행 조건의 사람 작업, spec §11 모델 행). 이 단계에서는 등록돼 있는지 확인한다. 개인 `~/.codex*`는 쓰거나 복사하지 않는다. [../approvals.md](../approvals.md)에 기록한다.
      - 시점: T16b 전(모델을 처음 쓰는 단계 전)이다. 이 티켓의 대화 레인이 모델을 쓰므로 이 티켓을 시작하기 전에 끝나 있어야 한다(설계 E9와 같다. 시점은 에이전트가 맞춘 정리이고 사용자 결정이 아니다). T17·T18은 이 준비가 끝났다고 전제한다.
      - 결과(D-14 변경, 사용자 2026-10-30 18:2x·20:1x): 봇 모델 실행기를 Claude로 바꿔 작업자 자격은 `auth.json` 시드가 아니라 구독 장기 토큰 `CLAUDE_CODE_OAUTH_TOKEN` 하나다(`platform/sandbox/values.yaml` `worker.profile.credentialKey`). 사람이 owner의 기존 보조 Claude 구독 계정에서 만들어 `/apps/homelab-bot/worker`에 넣었고, 2026-10-30 23:0x에 키 이름·모양만 확인했다. 그 계정의 학습 사용 설정은 꺼져 있다(사용자 확인 2026-10-31 00:2x). 토큰은 env-static이라 영속 공간에 사본이 없다. Codex 프로필로 돌아가면 위 시드 방식을 다시 쓴다.
   3. 봇 자리 Application `platform/bot-slot`의 `target` 변경 PR을 봇 등록 PR보다 먼저 병합한다(아래 "봇 자리 `target` 변경"). 병합 뒤 검증의 콜드스타트 (2) 앞부분으로 `bot-slot`이 봇 ns를 기다리는 상태인지 본다.
   4. 사람이 승인한 뒤 봇 등록 PR을 병합해 첫 배포를 한다. ArgoCDAppDegraded 경보(30분)가 울리기 전에 병합한다.
   5. T08b의 시험 수신기를 봇으로 바꾸고, 격리 공간에 작업자를 둔다(설계 E9). 공개 webhook 경로 `hooks.ukyi.app/github`도 T08a의 시험 수신기 `platform/edge-probe`에서 봇 Service로 넘기고, edge-probe는 그 디렉터리·root 템플릿 `edge-probe.yaml`·values의 `edgeProbe` 블록·Infisical 키를 함께 지운다(`platform/edge-probe/kustomization.yaml` 머리 주석, T13 봇 자리 확인). Alertmanager 봇 route를 켤 때 Telegram 형제 route를 함께 켠다. `continue: true`는 부모 receiver로 되돌려 보내지 않아, 형제 route가 없으면 경보가 봇으로만 가고 비AI 경로(AC-P11)가 끊긴다(설계 C.3.7). 결과: 봇 route와 Telegram 형제 route는 #1001(2026-10-31 00:03), 작업자는 #1000(같은 날 00:01). edge-probe 정리와 공개 webhook 이전은 PR #1003으로 열려 있고 사용자 결정 대기다(ns 삭제라 되돌리기 어렵다. `restore.md` 개수 정정도 그 PR 안).
      - App 설치 시점: 이 티켓은 App을 만들거나 설치하지 않는다(설계 E9). 리뷰 App(D-16) 생성·설치는 T17이 시험 저장소부터 한다. 변경 PR App(D-24)은 이름·설치 저장소를 T19에서 정하므로 T19 할 일에서 설치한다. 두 App은 HANDOFF에 해소 티켓(T17, T19)과 함께 적는다.
      - 작업자 배치(D-14, D-15): `sandbox` ns의 상주 파드 하나(동시성 1, replicas 1. `strategy: Recreate`는 T08b의 [제안]), 작업자 포트 8080. 작업자 egress의 코드 읽기는 T08b의 `codeload.github.com`만 그대로이고 `github.com`·`api.github.com`·`gist.github.com`은 뺀다. 작업자에는 GitHub 자격이 없다. 개인 `~/.codex*`는 쓰거나 복사하지 않는다.
      - 영속 공간과 첫 시드(D-14): T08b가 `platform/sandbox`에 만든 작업자 전용 영속 쓰기 공간(`CODEX_HOME`용 PVC 하나)을 쓴다. 작업자는 그 공간에 `auth.json`이 없을 때만 Infisical `/apps/homelab-bot/worker`의 시드를 복사한다. 그래서 처음 배치 때 미리 등록한 시드(할 일 4.2)가 영속 공간에 들어가고, 파드를 다시 만들 때는 갱신본을 시드로 덮지 않는다(설계 C.8 격리 행). 결과: D-14 변경으로 Claude 프로필에서는 이 공간에 자격을 두지 않고, PVC(`codex-home`)는 capability nonce 저장소(`.homelab-worker/nonces`)로 쓴다. `auth.json`은 Codex 프로필일 때만 생긴다(#1000).
      - 모델·인증 호스트(D-14): 구독 인증 Codex가 쓰는 모델·인증 호스트를 실측해 egress 허용 목록에 넣는다(설계 E9. T15에서는 미확인이었다). 결과: Claude 프로필의 호스트는 `api.anthropic.com` 하나다(`platform/sandbox/values.yaml` `worker.profile.egressHosts`). S12 첫 모델 호출(2026-10-31 07:2x)에서 프록시 CONNECT `api.anthropic.com:443` 200, 다른 호스트 거부 0건이었고 `claude.ai`·`platform.claude.com`은 필요 없었다. DNS 없는 파드에서 `HTTPS_PROXY`만으로 동작했다.
      - 파드 방화벽(U13)이 T08b에서 실패로 끝났으면 작업자를 호스트 전용 UID + nft로 둔다(D-15 대안). 결과: U13은 T08b에서 통과해 해당 없다.
      - 작업자 이미지의 빌드·배포 경로는 설계에 없었다(T15에서 봇 저장소 `ARCHITECTURE.md` §10을 근거로 미확인). 결과(계획 D2, 사용자 2026-10-30 11:4x): 작업자는 게시 서버와 같은 봇 이미지를 쓰고 command만 작업자 진입점으로 바꾼다. 봇 저장소 main 빌드(app-build, GHCR `ghcr.io/ukyi-app/homelab-bot`)의 digest를 사람 PR로 `platform/sandbox/values.yaml` `worker.image`에 고정하고, `gh attestation verify oci://ghcr.io/ukyi-app/homelab-bot@<digest> --owner ukyi-app`로 서명과 소스 커밋을 확인한다(#1000·#1006·#1011). 게시 서버만 `apps/homelab-bot/image.yaml` 자동 병합으로 따라가고, 모델 자격을 든 sandbox는 자동 경로에 넣지 않는다.
   6. 플랫폼 프롬프트 §9 시나리오 1 형태로 실행을 확인한다(배포 PR, 병합, Argo CD 배포, 실행 확인).
   - 못 하면 `blocked`와 사유를 HANDOFF에 적는다.
   - 승인은 [../approvals.md](../approvals.md)에 남긴다 (AC-X2).
5. 봇 중단 경보(OPS-02)를 실제로 확인한다. Gateway만 끊겼을 때 봇이 Ready를 유지해 webhook(8080)·경보 수신(8081)이 계속 되는지와 Gateway 연결 지표 경보가 오는지를 함께 본다. T16a가 만든 readiness 연동과 하트비트를 쓰려면 사람이 봇 전용 healthchecks.io 체크를 만들고 ping URL을 `/apps/homelab-bot/`에 등록한다(봇 저장소 `ARCHITECTURE.md` §8 제안). Bun 위 Discord Gateway의 네트워크 차단·복구 시험(discord.js 이슈 #10840, not planned 종료)을 여기서 한다. 실패하면 Node 24 전환을 검토한다 [가정: `ARCHITECTURE.md` §3]. 결과: 봇은 Node 24와 자체 Gateway(Discord SDK 없음)로 만들어 Bun 전제는 낡았다. 단절·복구 시험은 EVENT-03(nft로 봇 파드 443 DROP)으로 했고, 첫 실행에서 Gateway 지표가 1로 남은 결함을 봇 #20으로 고친 뒤 재시험이 통과했다. Gateway만 끊긴 동안에도 봇은 Ready였고 8080 스크레이프와 8081 경보 수신이 계속됐다(아래 "결과"의 완료 조건 대조, lead 실측 2026-11-02).
6. T16a PR #5(`ukyi-app/homelab-bot`, 병합 `7f649c9`)에서 이월한 Codex 리뷰 P2 6개를 봇 저장소 PR로 고친다. 마지막 재리뷰(head `1a639db`)에 P1이 없으면 병합하고 남은 P2는 이 티켓으로 옮긴다는 멈춤 규칙에 따른 것이다(사용자 2026-10-20). 스레드마다 처리 방향을 답글로 남겼다. 결과: 아래 다섯은 봇 PR #11(main `3fb389a`, 2026-10-30 11:22)로 고쳤다.
   - **capability nonce 정규화(`src/worker.ts`, 보안 성격):** 첫 배포 전에 고치도록 할 일 4의 선행 단계로 옮겼다.
   - **JSON 페이지 밖 marker(`src/discord.ts`):** 긴 `/list` 게시물의 각 페이지 뒤에 붙는 `[ref:...]`가 JSON 파싱을 깬다. marker를 JSON 필드나 별도 메타데이터로 옮긴다.
   - **모델 응답 생략 표시(`src/runtime.ts`):** 섹션 350자 `slice()`가 항목을 조용히 버린다. 완결 항목 단위로 줄이고 생략 건수를 표시한다(`summaryItems()`와 같은 방식).
   - **marker 검색 실패 backoff(`src/discord.ts`):** `external_id`가 없는 unknown 행이 매 `reconcile()`마다 최대 10페이지 history를 다시 조회한다. 검색 실패 때도 다음 대조 시각을 저장하고 조회 조건에 쓴다.
   - **`/retry` 큐 상한(`src/store.ts`):** 재시도 전이가 queued 개수를 보지 않아 `DEFAULTS.maxQueue`(100)를 넘을 수 있다. scheduler 행 잠금 아래에서 개수를 확인한 뒤 전이한다.
   - **read 타임아웃 중단(`src/read.ts`):** 5초 `Promise.race()`가 실제 요청을 멈추지 않아 반복 timeout에서 요청이 직렬성 밖에 쌓인다. `ReadTransport`에 `AbortSignal`을 넘겨 abort한다.
7. T17·T18·T20 봇 저장소 PR(#7·#8·#9, 2026-10-29)에서 이월한 Codex 리뷰 P2와 T16a 변경 요청을 봇 저장소 PR로 고친다. 같은 멈춤 규칙(1라운드 수정 → 재리뷰 → P1 없으면 병합)에 따른 것이고 스레드마다 답글을 남겼다. 각 STAGE를 실연동하기 전에 고친다. 결과(lead 결정 2026-11-02, 계획 S18): T17·T18·T20 P2는 그 경로(리뷰 레인·작업 레인·브리핑)가 T16b에서 꺼져 있어 T17·T18·T20으로 옮겼다(T17 할 일 6, T18 할 일 5·6, T20 할 일 1). T16a 변경 요청 `accept()` 잠금 순서는 봇 PR #11(`3fb389a`)에서 할 일 6의 P2 다섯과 함께 고쳤다.
   - **T17(`src/review.ts`·`src/review-input.ts`):** 중복 세대에 댓글 명시 요청의 `trigger`를 `comment`로 올림. 원격 조회 뒤 POST 직전 최신 정책(저장소 허용·revision·출력 분류·게시 상한) 재확인. `unknown` 게시 행 대조 대상을 커서로 순환(지금은 최신 20개만). 보안: `editScript` diff 계산의 메모리 상한(linear-space diff 또는 계산 전 복잡도 한도·deadline, 입력 한도 `maxDiffBytes`는 계산 뒤에만 본다).
   - **T18(`src/codex-process.ts`, 보안):** 작업 셸과 Codex `auth.json` 분리(별도 UID·컨테이너나 credential broker), 작업별 cgroup이 빌 때까지 완료·취소·해제 금지. 둘 다 실제 `TaskLane` 연결 전 필수이고, T18 사용자 결정 (2) 인증 파일 분리·(4) 작업별 세션 공간과 같은 범위다.
   - **T20(`src/briefing.ts`):** 예약을 끌 때(시각·시간대 설정을 비울 때) 이미 큐에 넣은 미전송 브리핑 outbox도 막는다. 기동 순서(원장 재적용 → 첫 tick → 게시자)와 함께 본다.
   - **T16a 변경 요청(`src/store.ts` `accept()`):** 스케줄러 행을 먼저 잠근 뒤 `jobs` 삽입의 외래 키 검사로 대화 행을 기다려, 같은 대화의 `/cancel`·`/model-status` 등과 잠금 순서가 역전된다(T18 작업자가 로컬 PostgreSQL 18.6에서 `55P03` 재현). 대화 행을 먼저 잠근다. 봇 저장소 `ARCHITECTURE.md` §12 T16a 변경 요청 6번.

### 봇 자리 `target` 변경 (설계 E9, C.8)

- T08b가 만든 `platform/bot-slot`의 `values.yaml`에서 `target`을 봇 ns `app-homelab-bot`, 라벨 `homelab-bot`, D-15가 정한 작업자 포트 8080·경보 수신 포트 8081로 바꾸고, `probe: false`로 시험 ns `bot-slot-probe`와 손으로 옮긴 정책을 지운다. 이 값 하나로 봇 쪽 NetworkPolicy의 대상, sandbox ingress의 출처, SA `bot-reader`의 ns가 함께 바뀐다. 작업자 포트는 `platform/sandbox`의 작업자 컨테이너 포트와 같아야 한다.
- `image.yaml` 밖의 platform 변경이라 자동 병합 대상이 아니고 사람이 검토 후 병합한다.
- 봇 등록 PR보다 먼저 병합하는 이유: 빈 클러스터에서 생기는 "봇 ns보다 봇 자리가 먼저 sync되는" 콜드스타트 순서를 운영에서 재현해 확인하려는 것이다. `bot-slot`은 대상 ns를 만들지 않고(`CreateNamespace` 없음) wave 1, `retry.limit: -1`, `retry.refresh: true`라 봇 ns가 생길 때까지 재시도하다 수렴해야 한다.

## 시범 운영 (완료 뒤)

- 이 티켓이 끝나면 허용 채널에서 읽기 조회만 실사용한다(V1 범위 조정 안 3, 확정(사용자 2026-10-18, T15)). V1 출시 판정 기준은 그대로다.
- 시작 전에 사람이 승인하고 [../approvals.md](../approvals.md)에 기록한다.
- **P-1 진행 중(사용자 승인 2026-11-02 18:31).** 범위는 허용 채널(작업공간·알림)에서 owner의 `/read`와 대화다. 대화는 도구를 실행하지 않아 읽기만 하고, 모델은 봇 전용 Claude 구독 한도를 쓴다. 작업·리뷰·브리핑 레인은 꺼진 채다. 허용 밖 사용자 응답이나 내부 자료 게시가 보이면 바로 멈추고 해당 시험을 `fail`로 기록한다. 증거 등급은 `authorized_external`·`production_observation`이고 V1 판정이 아니다(T21). 끝은 T17 완료 뒤 P-2 승인 때 다시 정한다.

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

## 결과 (2026-11-02)

실제 ID·tailnet 이름은 적지 않는다(D-23). 시각과 명령의 세부는 [../approvals.md](../approvals.md)의 2026-10-30~11-02 T16b 행이다. 판정 표(확인한 경계·수치·시각)는 봇 저장소 `docs/ai-bot/VERIFICATION.md`의 "T16b 실연동 결과" 절이고, 여기에는 판정 요약만 둔다. 등급은 `live`이고 T16a의 `mock`·`local_integration`과 섞지 않는다. 이 결과는 V1 출시 판정이 아니다(T21).

### 시험 판정 (`live`)

- **pass:** AUTH-01, AUTH-02, EVENT-04, CHAT-01, CHAT-02, READ-01, READ-02, SEC-01, OPS-02. 이 단계의 보안 경계 시험(AUTH-01, READ-02, SEC-01)도 실연동에서 pass다.
- **EVENT-03 pass:** 첫 실행(2026-11-02 13:09) 부분 fail. 놓친 메시지 복구와 healthchecks 경보는 됐지만 Gateway 지표가 DROP 동안 1로 남아 클러스터 안 경보가 없었다 → 봇 #20 → 재시험(14:10~14:24) pass(지표 0 → HomelabBotGatewayDisconnected Telegram, 풀린 뒤 41초에 재연결).
- **OPS-01 pass(조건 축소):** 사용자 승인으로 30+30 대신 10+10. 작업 레인이 닫혀 있어 "긴 작업 중"을 "10개 몰림"으로 쟀다. 유휴 하나씩 8건 p50 7.3초·max 16.5초, 몰림 10건 p50 22.3초·max 37.6초(모델 슬롯 1개).
- **EVENT-01 `not_run`:** 실제 Discord에서 중복 전달(RESUME 재전송, history와 live 교차)을 시점을 정해 만들 수 없고, 중복은 `events.semantic_key`로 조용히 흡수돼 로그·감사에 남지 않아 관측할 수 없다. 보조 사실: S16 동안 메시지마다 답 1건, 열린 outbox 0, EVENT-03 복구에서 중단 중 메시지 2건이 한 답으로 합쳐졌다(같은 대화의 대기 작업은 최신만 남김). 해소: T17(GitHub webhook 재전송 `duplicate_delivery`는 실연동에서 재현할 수 있다), Discord 경로는 T21.
- **EVENT-02 부분:** 상호작용 응답 경로는 pass, outbox 게시 경로는 `not_run`. 상호작용: `ack_uncertain`을 실측했다(EVENT-04의 `/retry`, logs `/read`). 사용자는 접수 응답을 받았는데 봇은 응답을 확인하지 못한 경우로, 중복 응답 없이 기록을 저장하고 작업은 한 번 실행했다. 봇 #21(REST 제한 분리) 뒤 #22 확인에서는 두 상호작용 모두 정상 ack였다. outbox: 요청은 Discord에 닿고 응답만 잃는 상황을 안전하게 만들 수단이 없어 실연동하지 않았다(`local_integration`은 T16a pass). 해소: T21.
- **DB 연결 끊김 pass:** lead 계획 S16이 EVENT-01 자리에 적은 "처리 중 DB 끊김"이다. `04` §4 정식 EVENT-01(중복 전달)이 아니다.

### 완료 조건 대조

- **시험 결과 기록:** 봇 저장소 VERIFICATION "T16b 실연동 결과"(등급 `live`, T16a 결과와 구분). 충족.
- **fail 없음, `not_run`은 사유와 해소 티켓:** 위 판정. 충족.
- **첫 배포 증거:** 등록 PR #995(2026-10-30 16:24) → 빈 DB 비밀번호를 바로잡은 뒤 18:1x 첫 배포 성공(마이그레이션 성공, homelab-bot Synced·Healthy, 파드 Ready, `publisher_started`·`gateway_ready`·`commands_registered`). 첫 모델 호출은 #1004 뒤 2026-10-31 07:2x. 충족.
- **콜드스타트 순서:** (1) 렌더(#994 확인): wave 최댓값 1, `bot-slot`이 그 wave, `CreateNamespace=true` 없음, `retry.limit` `-1`, `retry.refresh` `true`. 다만 명령의 마지막 줄은 `go 1`이다. T08c의 `go`가 같은 wave 1이고 `sort -k2 -n`이 같은 wave를 이름순으로 둔다. "bot-slot 뒤 wave 없음"이라는 뜻은 충족하고 글자 그대로는 아니다. (2) 재현: #994 병합(2026-10-30 16:21) → `namespaces "app-homelab-bot" not found. Retrying attempt #1`, 다른 앱 Synced·Healthy → #995 병합(2분 14초 뒤) → 16:28 전 `bot-slot` Synced·Healthy. `bot-slot`이 옛 시험 리소스를 먼저 prune한 것은 PR 설명의 가정과 달랐다. 봇 파드 Ready는 마이그레이션 문제로 18:1x였다. 충족.
- **시나리오 1:** 2026-10-30 16:50 #996(첫 실측, 옛 리비전 재시도로 반영이 늦었다), 2026-10-31 10:4x #1005(봇 #17 병합에서 배포 PR 자동 생성·자동 병합·Argo CD 배포·실행 확인까지 약 9분 30초), 2026-11-02 14:04 #1010(봇 #20·#21·#22). 충족.
- **설계 C.8 표 명령을 실제 봇으로:** 2026-10-30 18:1x 봇 파드 안: SA로 pods 200·Application CR 200·secrets 403·configmaps 403, 작업자 8080·Grafana 3000 열림, argocd-server·vmsingle·Alertmanager API·노드 10250·22 거부. READ-02 플랫폼 RBAC(`kubectl auth can-i`, 2026-10-31). 2026-11-02 18:0x~18:1x lead 실측(읽기만): `bot-reader`는 applications get·list가 `-n argocd`에서 yes이고 `-n default`·`-n app-homelab-bot`에서도 yes다. ClusterRole `homelab-readonly`가 클러스터 범위 get·list·watch라서다(`platform/bot-slot/templates/rbac.yaml`). Application 21개가 모두 argocd ns라 실제 노출 차이는 없고 봇 코드는 argocd ns만 읽는다. applications patch·update·delete·create, appprojects, argocd ns의 secrets·configmaps는 no. 같은 때 봇 파드(app 컨테이너)에서 vmsingle `:8428`, VictoriaLogs `:9428`, Alertmanager `:9093`은 ECONNREFUSED, 대조로 Grafana `:3000/api/health`는 200이었다. 봇 ns egress 허용은 같은 ns, DNS, PG 5432, 작업자 8080, Grafana 3000, API 6443, 사설 대역 밖 443뿐이다. 충족.
- **작업자 egress:** lead 실측(2026-11-02 18:2x, 운영 작업자 파드 `worker-7d7bddc7db-*`, 봇 이미지 097c93e, 읽기·연결 시도만). 프록시(`HTTPS_PROXY`, egress-proxy ClusterIP:3128) CONNECT: `codeload.github.com` 200, `api.anthropic.com` 200, `github.com`·`api.github.com`·`gist.github.com` 403, `claude.ai` 403, `example.com` 403. 프록시를 거치지 않은 직접 연결(외부 IP 443(1.1.1.1, GitHub IP), 노드 6443, kube-dns 53)은 모두 ECONNREFUSED(init 방화벽). S12 첫 모델 호출(2026-10-31 07:2x)에서도 다른 호스트 거부 0건이었다. 충족.
- **작업자 재생성 뒤 영속 공간 유지(`auth.json`이 시드로 덮이지 않음):** D-14 변경으로 Claude 프로필은 해당 없음. 자격은 읽기 전용 Secret 마운트(`/run/worker-credential`)로 받아 되쓰기가 없고 PVC에 자격을 쓰지 않는다. 영속 공간 유지는 실측했다(lead 2026-11-02 18:0x~18:1x, 읽기만, 파일 내용은 안 읽음): PVC `codex-home`(`/codex-home`)의 `.homelab-worker`(mtime 2026-10-30 15:02Z)가 11-02 파드 재생성(EVENT-04 12:45 삭제, #1011 14:14 교체) 뒤에도 남아 있고 `nonces/`는 17:50에 갱신됐다. 재생성 뒤에도 작업자는 `credential=present`로 기동했다. Codex 프로필의 `auth.json` 확인은 그 프로필로 돌아갈 때(T18) 다시 본다.
- **구독 계정 준비와 자격 등록 기록(D-14):** 바뀐 자격 기준으로 approvals 2026-10-30 18:2x(실행기 결정), 20:1x(계정 결정), 23:0x(토큰 등록 확인), 2026-10-31 00:2x(학습 사용 설정 꺼짐). 충족.
- **봇 저장소 public·보안 설정·운영 산출물 없음:** 2026-11-02 읽기 확인: public, ruleset `app-main` active, secret scanning·push protection enabled, fork PR 승인 `all_external_contributors`. 운영 산출물(HANDOFF, 시험 원자료, 정책 실제 값)은 저장소 밖(`homelab-bot-ops`, Infisical, lead 작업 파일). 충족.
- **Alertmanager 봇 route + Telegram 형제 route:** #1001(2026-10-31 00:03). 봇 정상: S14 시험 경보(2026-10-31 00:38) bot·telegram 각 +1, SEC-01 시험 경보(2026-11-02 12:42) 각 1, 실패 0. replicas 0: #1008(13:25) → TargetDown(bot-slot) 13:31 Telegram. 충족.
- **Gateway만 끊긴 동안 Ready·8081 수신(할 일 5):** EVENT-03 재시험 차단(2026-11-02 14:10:04~14:24:04) 동안 vmsingle 기준(lead 실측 18:0x~18:1x): `kube_pod_container_status_ready{container="app"}` 1분 최솟값 계속 1, `up{job="bot-slot"}`(8080 `/metrics` 스크레이프) 계속 1, `alertmanager_notifications_total{receiver_name="bot"}` 14:22 8→9(HomelabBotGatewayDisconnected firing을 차단 중 8081로 받음)·14:27 9→10(해소), 실패 합계 0(bot·telegram·healthchecks). 봇 파드 재시작 0(시작 14:06:26). 충족.
- **HANDOFF:** `ukyi-app/homelab-bot-ops` `handoffs/foundation-deploy.md`(2026-11-02 18:20 push, 커밋 `a58a197`). 충족.

### 후속 (해소 티켓)

봇 동작. 해소는 T21이다(7·8은 그 단계 재확인 때).

1. 응답할 틈 없는 강제 종료(OOM·노드 정지) 때 실행 중 작업이 `unknown`으로 남고 Discord 명령으로 풀 수 없다(EVENT-04의 미시험 부분).
2. `model_timing.queueWaitMs`가 재대기 뒤 `created_at` 기준이라 실제 대기를 보이지 않는다. 받은 시각 기준 지표가 필요하다.
3. 조용한 거부: 허용 밖 채널·DM 메시지와 정책 밖 서비스 `/read`가 감사·로그 없이 버려진다.
4. `/list`에 작업 종류(chat·read 등) 표시.
5. history 복구가 채널 GET을 반복한다.
6. reconcile 루프 한 바퀴의 시간 예산(게시자 `unknown` 대조가 행당 최대 50초).
7. EVENT-01 Discord 경로의 관측 수단(중복 흡수 감사 기록).
8. EVENT-02 outbox 경로 실연동.

이미 고치고 실연동으로 다시 확인한 관찰(봇 #20·#21·#22): Gateway DROP 때 지표, REST 1초 제한의 `ack_uncertain`, `/read` epoch 시각·60초 창, 네임스페이스 추측, mention 플래그 오해, `/revoke` 자기 명령 인식, `/list` JSON.

플랫폼·사람:

- 공개 webhook 이전 PR #1003(edge-probe 삭제, `hooks.ukyi.app/github`을 봇으로): 열림, 사용자 결정 대기. ns 삭제라 되돌리기 어렵다. `restore.md` 개수 정정은 그 PR 안에 있다.
- 사람 정리(계획 H7): Infisical `/apps/homelab-bot/worker/WORKER_PROBE` 삭제, #1003 병합 뒤 `/apps/edge-probe/*`와 시험 webhook 정리. 후보: `/apps/homelab-bot/ARGOCD_READER_TOKEN`(D9 뒤 차트 secrets 목록과 봇 코드에 없다. 키가 남아 있으면 지운다).
- D-14 변경(Claude 구독 실행기)을 봇 저장소 `docs/ai-bot/prompts/`, `platform/design-prompt.md`, T17·T18 티켓 머리말(선행 결정, `auth.json` 시드·재시드 문장)에 맞춘다: T17·T18 착수 때. spec §5.1·§10·§11과 설계 C.8·E9·F는 이 결과와 함께 고쳤다.
- 시범 P-1: 2026-11-02 18:31 사용자 승인, 진행 중(위 "시범 운영").
