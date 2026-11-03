# T20 봇 MEMORY_BRIEFING

- 단계: P4 봇 V1
- 상태: 완료 (2026-11-03. 실연동 2026-11-02~03: 원장(NUC SSD 계약 v1)·기동 장벽·기억 명령·일일 브리핑 운영 적용. MEM-01·BRIEF-01·DATA-02·AUTH-02(기억 명령 경로) live pass, fail 없음. DATA-02는 `homelab db restore`로 삭제 전 시각 복원 뒤 원장 재적용(homelab #1026·#1027), AUTH-02는 허용 밖 채널 `/memory-search`를 봇이 처리하지 않음. 미확인 칸의 해소 티켓: 브리핑 인증서·복원 검증 원본 T24, Codex 작업 상태·질문 대기 칸 T18, 기억을 모델 맥락에 넣는 경로(SEC-01)는 V1 코드에 없어 T21이 다시 확인. 결과표는 봇 저장소 `docs/ai-bot/VERIFICATION.md` "T20 실연동 결과", HANDOFF는 private 운영 저장소 `handoffs/memory-briefing.md`. 시범 P-1 확장 진행 중(2026-11-03, 아래 "시범 운영"). 로컬·mock 구현은 2026-10-29 봇 PR #8 `82e2a45`)
- 명세: [../spec.md](../spec.md)
- Blocked by: T16a(착수), T16b(완료)
  - 착수: [T16a](T16a-bot-foundation-local.md) 뒤. 이 티켓을 실제로 막는 FOUNDATION의 예약 기능을 T16a가 로컬·mock으로 만든다(V1 범위 조정 안 3).
  - 완료: [T16b](T16b-bot-foundation-deploy.md) 뒤. 브리핑을 실제 D-17 브리핑 채널로 보내는 시험(BRIEF-01 `authorized_external`)은 배포된 봇이 필요하다.
- 선행 결정: D-17 (확정(사용자 2026-10-18, T15): 브리핑은 알림·리뷰·브리핑 채널. 브리핑 시각은 매일 08:50 Asia/Seoul(확정(사용자 2026-10-20, T16a))), D-12 T20 후속 (확정(사용자 2026-11-02): 삭제 원장은 NUC 두 번째 NVMe SSD, `LABEL=bulk-ssd` → `/mnt/bulk`)
- 연결 AC: AC-B7
- 수행: 개발 에이전트 (`STAGE=MEMORY_BRIEFING`)

## 목표

`01` §8: 출처 기반 기억과 일일 브리핑 (R16~R18).

## 메모

`01`의 권장 순서는 CHANGE_PR 뒤지만, 실제로 막는 것은 FOUNDATION의 예약 기능뿐이다. 그래서 T17·T18과 병행할 수 있다. 예약 기능은 T16a가 만든다. 브리핑에 넣는 Codex 작업 상태와 승인·질문 대기(`01` §8 일일 브리핑)는 T18이 끝난 뒤 연결한다.

DATA-02: 봇 DB는 공유 PostgreSQL 백업(14일 보존, spec §5.1 "설계 기본값")에 들어간다. 삭제한 기억도 14일 동안 백업에 남을 수 있으므로 삭제 표식은 복원 대상 밖의 삭제 원장에 두고, 원장 기록이 확인된 뒤에만 삭제 완료로 응답하며, 기동 때 원장의 삭제를 다시 적용한다. 기억 ID는 재사용되지 않는 값으로 두고 원장에 `created_at`을 함께 둔다 [가정: 봇 저장소 `ARCHITECTURE.md` §7 제안, PR #3 Codex 리뷰 반영].

삭제 원장 위치(사용자 2026-11-02, spec D-12 "T20 후속"): NUC 두 번째 NVMe SSD(ext4, 라벨 `bulk-ssd`)의 파일 원장 `/mnt/bulk/homelab-bot/deletion-ledger/`(`deletions.jsonl` + 초기화 표식 `ledger.json`)다. R2 원장은 고르지 않았고 새 자격은 없다. 사람이 `sudo host/install.sh --cluster prod --bulk-ssd`로 마운트와 원장 첫 초기화를 한다. 봇은 파일을 만들지 않고, 파일·표식이 없으면 빈 원장으로 열지 않고 멈춘다. 게시 서버에만 PVC `deletion-ledger`로 붙이고 배포는 `Recreate`다(단일 작성자). 받아들인 위험: NUC 본체와 SSD를 함께 잃으면 R2에서 DB만 돌아와 지운 기억이 되살아날 수 있다. 평상시의 미마운트·파일 유실·잘못된 볼륨은 받아들이지 않는다(멈춤·경보).

## 할 일

1. 브리핑을 실연동하기 전에 봇 저장소 PR #8(2026-10-29)에서 이월한 Codex 리뷰 P2를 고친다(`src/briefing.ts`): 예약을 끌 때(시각·시간대 설정을 비울 때) 이미 큐에 넣은 미전송 브리핑 outbox도 막는다. 기동 순서(원장 재적용 → 첫 tick → 게시자)와 함께 본다. T16b 할 일 7에서 옮겼다(lead 결정 2026-11-02. 브리핑이 T16b에서 꺼져 있었다). 같은 멈춤 규칙(1라운드 수정 → 재리뷰 → P1 없으면 병합)을 따른다.
   - 결과(2026-11-02): 봇 PR #24 `cd49182`(Codex 지적 없음). 실연동 뒤 브리핑 회차·사본 중복 없음은 재기동 세 번(11-03 10:18·10:45·14:09)으로 확인.

## 시범 운영

- **P-1 확장 진행 중(사용자 승인 2026-11-03).** T16b 시범 P-1(허용 채널에서 owner의 `/read`와 대화)에 기억 명령 `memory-*`와 일일 브리핑(매일 08:50 Asia/Seoul, 알림 채널)을 더한다. owner만 대화 채널에서 실제 정보를 저장·검색·정정·제외·삭제한다. PR 리뷰·Codex 작업 레인은 T17·T18 전이라 꺼진 채다.
- 실사용 전에 실연동 시험 기억 8건을 지웠다(2026-11-03 13:08~13:12, owner 맥의 Codex가 `memory-delete`. 8건 `deleted`, 원장 recorded 8, 삭제 대기 0).
- 멈춤 조건: 기억이 허용 밖 채널이나 owner 밖 사용자에게 보임, 지우거나 저장 제외한 기억이 검색·브리핑에 나옴, 원장 경보(failed·fenced 5분, closed·degraded 30분), 브리핑 중복 발송. 보이면 바로 멈추고 해당 시험을 `fail`로 기록한다. 멈춤은 `apps/homelab-bot/values.yaml`에서 브리핑만이면 `BRIEFING_*` 두 줄, 기억까지면 `MEMORY_LEDGER_DIR`도 지우는 PR이다(원장 env가 없으면 기억과 브리핑이 함께 닫힌다).
- 증거 등급은 `authorized_external`·`production_observation`이고 V1 판정이 아니다(T21). 끝은 T17 완료 뒤 P-2 승인 때 다시 정한다.

## 완료 조건

- `04` §4 시험 MEM-01, BRIEF-01, DATA-02, AUTH-02 결과가 있다 (spec §7 AC-B7).
- spec §7 "단계 AC 공통 완료 규칙"을 따른다. 배정된 시험에 `fail`이 없다. `blocked`·`not_run`은 사유와 해소 티켓을 함께 적는다. 이 단계에 배정된 보안 경계 시험은 없다.
- HANDOFF가 있다.

## 검증

`04` §4 시험.
