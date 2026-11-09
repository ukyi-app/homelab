# T33 봇 V1 정비: 승인 digest 분할과 명령 재등록 (T21 4회차 low)

- 단계: P4 후속 (T21 4회차 감사의 low 발견)
- 상태: 진행 중 (2026-11-09 착수, 사용자 결정: 시범 운영 전에 정비)
- 명세: [../spec.md](../spec.md)
- Blocked by: T21
- 연결 AC: AC-B6 (R13), AC-B3 (F05·R02)
- 수행: 에이전트 (구현은 Claude 작업자, 검토·전체 시험·배포는 lead)

## 목표

T21 4회차 판정(`READY_FOR_SCOPED_PILOT`, 2026-11-09)에 남은 low 발견 셋 가운데 시범 운영 중 바로 불편한 둘을 고친다. 근거는 봇 저장소 `docs/ai-bot/V1_RELEASE_REPORT.md`의 A05·A08 절이다.

- **A05 승인 digest 분할:** `messagePages()`가 1800자로 잘라, 파일이 많거나 경로가 길면 CHANGE 승인 명령의 digest가 두 메시지로 갈린다. 다른 digest는 거부되므로 권한 경계 결함은 아니지만, 복사해 승인하기 어렵다.
- **A08 명령 재등록:** Discord guild 명령 GET 응답이 `contexts`·`integration_types`를 생략해, 등록 비교가 늘 어긋나고 재시작마다 PUT이 나간다(`guild: updated`). 불필요한 쓰기와 한도 소비다.

A07(unknown 후보 상한 뒤 진행성, `needs_verification`)은 이번 범위가 아니다.

## 할 일

1. A05: 승인 명령(digest 포함)을 나뉘지 않는 단위로 보낸다(별도 메시지 또는 분할 금지 블록). 경계 직전·중간·직후에 digest가 오는 시험.
2. A08: guild 명령 비교에서 의미 없는 필드를 빼거나 API 응답 기본값을 정규화한다. 실제 생략 모양으로 연속 등록하면 PUT 0, 정의가 바뀌면 PUT 1인 시험.
3. 봇 PR, 운영 배포, 봇 `VERIFICATION.md` 기록. 배포 뒤 재시작 로그에 `guild: updated`가 없는지 확인.

## 완료 조건

- 두 시험이 새 코드에서 통과하고 기존 시험이 통과한다.
- 배포 뒤 재시작에서 명령 재등록이 없고(`guild: updated` 없음), 결과가 봇 `VERIFICATION.md`와 [../approvals.md](../approvals.md)에 있다.

## 검증

`04` §4의 R13(승인 digest)·F05(명령 등록) 관련 시험.
