# T16 봇 FOUNDATION

- 단계: P4 봇 V1
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- 설계: [../platform/design.md](../platform/design.md) E.1 E9, C.8 "봇 자리 Application"
- Blocked by: T13, T15
- 선행 결정: D-05 (확정(사용자 2026-10-18, T05): 공유 PostgreSQL 인스턴스 + 앱별 DB·역할), D-09 (확정(사용자 2026-10-18, T05): 옛 계열 최소 관측 구성), D-10 (확정(사용자 2026-10-18, T05): homelab 알림용 Telegram 새 봇 + healthchecks.io), D-13 (확정(사용자 2026-10-18, T14): 봇 저장소 `ukyi-app/homelab-bot`, 앱 이름 `homelab-bot`, 운영 산출물은 봇 저장소 밖), D-15, D-16, D-17, D-24 (T15)
- 연결 AC: AC-B3
- 수행: 개발 에이전트 (`STAGE=FOUNDATION`) + 사람 (Discord 봇 계정·Intents, Infisical 봇 시크릿 등록, 봇 자리 `target` 변경 PR 검토·병합, 첫 배포 승인)

## 목표

`01` §4: Discord 대화, 영속 작업 저장소, 읽기 전용 홈랩 조회 (R01~R07). 봇을 플랫폼에 처음 배포한다.

## 할 일

1. 시작 전에 T15에서 `blocked`로 남긴 플랫폼 실측 항목을 다시 확인한다.
2. 이벤트·작업·outbox 스키마와 게시 계층을 만든다. 이 공유 계약은 이 티켓이 소유하고, T17·T18·T20은 추가 변경만 한다.
3. `01` §4의 입력·허용·금지·완료·실패 계약을 코드와 시험에 반영한다.
4. 첫 배포를 아래 순서로 한다(설계 E9).
   1. 에이전트: 플랫폼 CLI로 봇을 등록하고, DB를 추가하고, 시크릿 참조를 선언한다. 값은 넣지 않는다. 봇 values에 `serviceAccountName: bot-reader`를 둔다(설계 C.4.5).
   2. 사람: Infisical에 봇 시크릿을 등록한다. 게시 서버 값은 `/apps/homelab-bot/`, 작업자 값은 `/apps/homelab-bot/worker`로 나눈다(설계 E9). 봇이 실행 중 읽는 runtime-policies와 허용 목록의 실제 값도 `/apps/homelab-bot/`에 둔다(D-13).
   3. 봇 자리 Application `platform/bot-slot`의 `target` 변경 PR을 봇 등록 PR보다 먼저 병합한다(아래 "봇 자리 `target` 변경"). 병합 뒤 검증의 콜드스타트 (2) 앞부분으로 `bot-slot`이 봇 ns를 기다리는 상태인지 본다.
   4. 사람이 승인한 뒤 봇 등록 PR을 병합해 첫 배포를 한다. ArgoCDAppDegraded 경보(30분)가 울리기 전에 병합한다.
   5. 봇 리뷰 App(D-16)과 변경 PR App(D-24)을 설치하고, T08b의 시험 수신기를 봇으로 바꾸고, 격리 공간에 작업자를 둔다(설계 E9). Alertmanager 봇 route를 켤 때 Telegram 형제 route를 함께 켠다. `continue: true`는 부모 receiver로 되돌려 보내지 않아, 형제 route가 없으면 경보가 봇으로만 가고 비AI 경로(AC-P11)가 끊긴다(설계 C.3.7).
   6. 플랫폼 프롬프트 §9 시나리오 1 형태로 실행을 확인한다(배포 PR, 병합, Argo CD 배포, 실행 확인).
   - 못 하면 `blocked`와 사유를 HANDOFF에 적는다.
   - 승인은 [../approvals.md](../approvals.md)에 남긴다 (AC-X2).

### 봇 자리 `target` 변경 (설계 E9, C.8)

- T08b가 만든 `platform/bot-slot`의 `values.yaml`에서 `target`을 봇 ns `app-homelab-bot`, 라벨 `homelab-bot`, D-15가 정한 작업자 포트·경보 수신 포트로 바꾸고, `probe: false`로 시험 ns `bot-slot-probe`와 손으로 옮긴 정책을 지운다. 이 값 하나로 봇 쪽 NetworkPolicy의 대상, sandbox ingress의 출처, SA `bot-reader`의 ns가 함께 바뀐다.
- `image.yaml` 밖의 platform 변경이라 자동 병합 대상이 아니고 사람이 검토 후 병합한다.
- 봇 등록 PR보다 먼저 병합하는 이유: 빈 클러스터에서 생기는 "봇 ns보다 봇 자리가 먼저 sync되는" 콜드스타트 순서를 운영에서 재현해 확인하려는 것이다. `bot-slot`은 대상 ns를 만들지 않고(`CreateNamespace` 없음) wave 1, `retry.limit: -1`, `retry.refresh: true`라 봇 ns가 생길 때까지 재시도하다 수렴해야 한다.

## 완료 조건

- `04` §4 시험 AUTH-01·02, EVENT-01~04, CHAT-01·02, READ-01·02, SEC-01, OPS-01·02의 결과가 기록돼 있다 (spec §7 AC-B3).
- spec §7 "단계 AC 공통 완료 규칙"을 따른다. 배정된 시험에 `fail`이 없다. `blocked`·`not_run`은 사유와 해소 티켓을 함께 적는다. 이 단계의 보안 경계 시험(AUTH-01, READ-02, SEC-01)은 이 경로에서 최소 `mock` 또는 `local_integration`으로 `pass`다.
- 봇이 플랫폼에 처음 배포됐다는 증거(배포 PR, Argo CD 상태, 실행 확인)가 있다.
- 봇 자리 Application의 콜드스타트 순서 확인(아래 검증 (1)·(2))을 통과했다.
- 봇에 대해 시나리오 1을 통과했다(두 번째 커밋의 자동 병합 포함). 설계 C.8 표 명령을 실제 봇(실제 차트 렌더)으로 다시 통과했다(설계 E9).
- 봇 저장소 `ukyi-app/homelab-bot`이 public이고 보안 설정(D-29)이 켜져 있으며, 운영 산출물(evidence, handoffs, runtime-policies 실제 값 등)이 저장소에 없다(D-13, 설계 C.8 봇 저장소).
- Alertmanager 봇 route를 켠 뒤(Telegram 형제 route 함께) 봇이 정상일 때와 replicas 0일 때 모두 시험 경보가 Telegram에 도착했다.
- HANDOFF가 있다.

## 검증

`04` §4 시험. `mock`과 실제 연동 결과를 구분한다.

봇 자리 Application의 콜드스타트 순서(설계 E9 검증):

- (1) 렌더: `helm template root platform/root -f platform/root/values-prod.yaml | yq -N 'select(.kind == "Application") | .metadata.name + " " + (.metadata.annotations."argocd.argoproj.io/sync-wave" // "0")' | sort -k2 -n | tail -2` → 마지막 줄이 `bot-slot 1`이고 그 앞 줄의 wave는 0 이하(뒤 wave 없음). 같은 렌더에서 `bot-slot`의 `spec.syncPolicy`에 `CreateNamespace=true`가 없고 `retry.limit`이 `-1`, `retry.refresh`가 `true`다.
- (2) 재현: `target` 변경 PR을 봇 등록 PR보다 먼저 병합한다 → `kubectl -n argocd get application bot-slot -o jsonpath='{.status.operationState.phase} {.status.operationState.message}'`가 phase `Running`이고 메시지에 `namespaces "app-homelab-bot" not found`와 `Retrying attempt`가 있다(무제한 재시도라 Failed가 되지 않는다). root·`bot-slot` 밖의 Application은 Synced·Healthy 그대로다 → 봇 등록 PR 병합(ArgoCDAppDegraded 30분 경보 전에) → backoff 상한 5분 안팎에 `bot-slot` Synced·Healthy, SA `bot-reader`가 생긴 뒤 봇 파드 Ready.
- 재현은 root의 wave 진행을 다시 거치지 않으므로 (1)과 함께 본다.

## 되돌리는 방법

- `homelab app remove homelab-bot`(데이터 보존)과 봇 자리 `target`을 T08b의 시험 값(ns `bot-slot-probe`, 시험 라벨·포트)으로 되돌리고 `probe: true`를 함께 켜는 PR(설계 E9, C.8). 시험 ns는 `probe: true`일 때만 선언된다. `target`을 봇 값으로 남기면 다음 콜드스타트에서 `bot-slot`이 끝없이 기다린다.
- App 설치 해제.
- 되돌리기 실행도 [../approvals.md](../approvals.md)에 기록한다.
