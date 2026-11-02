# T20 봇 MEMORY_BRIEFING

- 단계: P4 봇 V1
- 상태: 진행 중 (로컬·mock 구현 병합 2026-10-29, 봇 저장소 PR #8 `82e2a45`, 시험 333. 완료는 T16b 뒤. 삭제 원장 위치는 NUC 두 번째 NVMe SSD로 확정(사용자 2026-11-02, spec D-12 "T20 후속"). 봇 저장소 `docs/ai-bot/DECISIONS.md` T20의 "결정 대기"는 봇 저장소 PR이 고친다)
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

## 완료 조건

- `04` §4 시험 MEM-01, BRIEF-01, DATA-02, AUTH-02 결과가 있다 (spec §7 AC-B7).
- spec §7 "단계 AC 공통 완료 규칙"을 따른다. 배정된 시험에 `fail`이 없다. `blocked`·`not_run`은 사유와 해소 티켓을 함께 적는다. 이 단계에 배정된 보안 경계 시험은 없다.
- HANDOFF가 있다.

## 검증

`04` §4 시험.
