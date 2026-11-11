# C44 방식 전환 Telegram 알림

- 단계: 8 한도 뒤 API 크레딧
- 상태: 대기 (선행: C41)
- 명세: 봇 `docs/ai-bot/COLLEAGUE_SPEC.md`의 C38이 더한 절·AC(알림)
- Blocked by: C41
- 연결 AC: C38이 정한 번호(조사 AC-A10의 알림 쪽)
- 수행: 에이전트 + 사람(homelab 설정 PR 검토·병합, 발화 시험 승인)
- 저장소·PR: homelab PR 하나(`platform/observability`)
- 파일 소유: homelab `platform/observability/stack/vmalert/rules/bot.yaml`과 그 시험, 필요하면 route
- 설계 계약: 조사 3.5. 앞선 예: C21(운영 알림). 규칙은 실제 지표와 대조한다(가짜 series만 믿지 않는다).

## 목표

owner가 Telegram으로 API로 넘어감, 구독으로 돌아옴, API 잠김을 안다. 짧게 되풀이되는 전환은 한도 구간마다 한 번으로 묶인다(결정 5/6).

## 할 일

1. C41의 누계·마지막 시각 지표로 넘어감·돌아옴 규칙을 만든다. 순간 상태 gauge에만 기대지 않는다.
2. API 잠김 규칙은 바로 알리고, 잠금이 풀릴 때까지 유지한다.
3. "해소" 알림이 API 고장 복구와 구독 복귀를 헷갈리게 하지 않도록 사건을 나눈다.
4. `service` 라벨 없이 Telegram 경로를 쓴다. Discord 운영 경보는 만들지 않는다. 문구에 잔액·청구·포함분을 쓰지 않는다.
5. 규칙 단위 시험과, 배포 뒤 운영 vmsingle의 실제 지표 이름 대조.

## 완료 조건

- [ ] 세 사건의 규칙이 단위 시험을 통과한다(S4).
- [ ] 운영 지표 이름·라벨이 규칙과 맞다(운영 읽기).

## 검증

- 경계: S4, 운영 읽기. 발화는 C45. 명령: homelab `pre-commit run --files`, `bun run ci`.
- 잡는 실패: 규칙·지표 불일치. 못 잡는 범위: 실제 Telegram 도착(C45).

## 결과

(구현 뒤 채운다)
